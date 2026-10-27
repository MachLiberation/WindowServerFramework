//
//  WXFDecor.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Window decor (WXFDecor.h). docs/decor-internals.md has the IDA evidence for each step.
//
// Each decorated window's server-side tree (WS::CAWindowContent at window+24) has a root layer,
// "Server root" (content+136), in WindowServer's own local context for the window (content+64).
// initialize_ca_content_for_context adds one sublayer to it (content+144: shadow, corners, the window
// and the application's content inside), and nothing touches the root's sublayers after that. Decor
// adds a container below that sublayer and one above it.
//
// Core Animation in WindowServer: every CALayer is created, changed and released inside CAScope, an
// explicit transaction (with its own autorelease pool) that commits only the windows' contexts, as
// WSCAContextScopeTransaction does. A change outside one makes CA::Transaction::ensure_implicit push an
// implicit transaction on the main thread, and the server's own commits then nest inside it and never go
// out. No WindowServer function that opens its own transaction is called while CAScope is open.

#include <WindowServerFramework/WXFDecor.h>
#include <WindowServerFramework/WXFMisc.h>
#include <WindowServerFramework/WXFCAContextRetriever.h>
#include "WXFHooks-Private.h"
#include <dlfcn.h>
#include <os/lock.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <objc/message.h>
#include <os/log.h>
#include <pthread.h>

// The tree's origin is the bottom left, y up: the shield's debug label is pinned to MinX + 20,
// MaxY - 20 (WS::create_shield_window_common), and decor drawn on that assumption sat right, live.
#define kOriginBottomLeft 1

static const double kTickInterval = 1.0 / 60.0;

// WS::CAWindowContent, from initialize_ca_content_for_context (0x1873e9f14).
enum { kWindowContent = 24, kContentContext = 64, kContentRoot = 136, kContentFrame = 144 };

// --- Model ----------------------------------------------------------------------------------
@class WXFDDecor;

@interface WXFDElement : NSObject {
@public
    uint32_t          ident;
    __unsafe_unretained WXFDDecor *decor;
    CALayer          *layer;
    CGSize            natural;
    WXFDecorPlacement placement;
    float             opacity;
    bool              hidden, below, followCorners, dirty;
    CGFloat           baseRadius;
}
@end
@implementation WXFDElement
@end

@interface WXFDDecor : NSObject {
@public
    uint32_t   ident, windowID;
    CGXWindow *target;
    void      *content;            // the WS::CAWindowContent the containers are in
    id         context;            // its CAContext (content+64), committed with our changes
    CALayer   *container[2];       // 0 in front of the window, 1 behind it
    NSMutableArray<WXFDElement *> *elements;
    CGSize     laidOutSize;
    CGRect     bounds;             // what the frame shape hook adds, as last published
    bool       boundsChanged;
    CGFloat    laidOutRadius;
    bool       dirty;
    NSMutableArray *rules;         // the WXFDRules that set it up, for `resized`
    bool       sizeChanged;
    WXFDecorWindowInfo info;
}
@end
@implementation WXFDDecor
@end

@interface WXFDRule : NSObject {
@public
    uint32_t     ident;
    WXFDecorRule rule;
}
@end
@implementation WXFDRule
@end

// --- State ----------------------------------------------------------------------------------
static pthread_mutex_t gLock;
static NSMutableArray<WXFDDecor *> *gDecors;
static NSMutableArray<WXFDRule *> *gRules;
static NSMutableSet<NSNumber *> *gPending;      // windows to look at on the next tick
static NSMutableSet<NSNumber *> *gWaiting;      // seen, not decoratable yet: looked at again later
static NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *gEvaluated;   // window -> rules run
static uint32_t gNextID = 1;
static bool gStarted, gAvailable, gTickScheduled;
static unsigned gTicks;
static WXFCAContextRetrieverRef gRetriever;

static os_log_t Log(void) {
    static os_log_t log;
    if (!log) log = os_log_create("com.windowserverframework", "decor");
    return log;
}

static void Lock(void) { pthread_mutex_lock(&gLock); }
static void Unlock(void) { pthread_mutex_unlock(&gLock); }

static void InitState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&gLock, &attr);
        gDecors = [NSMutableArray new];
        gRules = [NSMutableArray new];
        gPending = [NSMutableSet new];
        gWaiting = [NSMutableSet new];
        gEvaluated = [NSMutableDictionary new];
    });
}

// --- Core Animation scope -------------------------------------------------------------------
// WSCAContextScopeTransaction: begin, no actions, no signposts, the changes, commit only these
// contexts. The inner pool frees what `work` released before the commit, not later in the main
// thread's pool.
static void CAScope(void (^work)(void)) {
    @autoreleasepool {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        SEL signposts = NSSelectorFromString(@"setDisableSignPosts:");
        if ([CATransaction respondsToSelector:signposts])
            ((void (*)(id, SEL, BOOL))objc_msgSend)([CATransaction class], signposts, YES);
        @autoreleasepool { work(); }
        NSMutableArray *contexts = [NSMutableArray new];
        for (WXFDDecor *d in gDecors)
            if (d->context && ![contexts containsObject:d->context]) [contexts addObject:d->context];
        SEL committing = NSSelectorFromString(@"setCommittingContexts:");
        if (contexts.count && [CATransaction respondsToSelector:committing])
            ((void (*)(id, SEL, id))objc_msgSend)([CATransaction class], committing, contexts);
        [CATransaction commit];
    }
}

// --- Placement ------------------------------------------------------------------------------
WXFDecorPlacement WXFDecorPlacementMake(CGPoint windowAnchor, CGPoint elementAnchor, CGPoint offset) {
    WXFDecorPlacement p = {0};
    p.windowAnchor = windowAnchor;
    p.elementAnchor = elementAnchor;
    p.offset = offset;
    p.scale = 1;
    return p;
}

// The element's layer for a window of `size`, in the root's space (window-local, origin bottom left).
// Only inside CAScope.
static void ApplyLayer(WXFDElement *e, CGSize size, CGFloat windowRadius) {
    const WXFDecorPlacement *pl = &e->placement;
    CGFloat w = pl->size.width + pl->stretch.width * size.width;
    CGFloat h = pl->size.height + pl->stretch.height * size.height;
    if (pl->size.width == 0 && pl->stretch.width == 0) w = e->natural.width;
    if (pl->size.height == 0 && pl->stretch.height == 0) h = e->natural.height;
    CGFloat s = pl->scale != 0 ? pl->scale : 1;
    CGPoint position = CGPointMake(pl->windowAnchor.x * size.width + pl->offset.x,
                                   pl->windowAnchor.y * size.height + pl->offset.y);
    CGPoint anchor = pl->elementAnchor;
    CGFloat rotation = pl->rotation;
#if kOriginBottomLeft
    position.y = size.height - position.y;
    anchor.y = 1 - anchor.y;
    rotation = -rotation;
#endif
    CALayer *layer = e->layer;
    layer.bounds = CGRectMake(0, 0, MAX(w, 0), MAX(h, 0));
    layer.anchorPoint = anchor;
    layer.position = position;
    layer.affineTransform = CGAffineTransformScale(CGAffineTransformMakeRotation(rotation), s, s);
    layer.opacity = e->hidden ? 0 : e->opacity;
    layer.hidden = e->hidden || w <= 0 || h <= 0;
    if (e->followCorners || e->baseRadius > 0)
        layer.cornerRadius = e->baseRadius + (e->followCorners ? windowRadius : 0);
    e->dirty = false;
}

// --- Render bounds --------------------------------------------------------------------------
// Each window's tree is rendered by its own CARenderUpdateBegin2, whose bounds ca_window_prep_ingestion_phase
// takes from CGXWindow::frame_bounds() (0x1873eba2c): the window's shape grown by its shadow radius. Live,
// decor stopped exactly there. The FrameBounds hook adds the decor's bounds to that rect. The FrameShape
// hook does the same for CGXCopyScreenFrameShapeForWindow (0x1872ad070), the region the server's damage and
// visibility shapes are made from, so the decor's area is repainted when the window moves. The tick publishes them here, window-local (origin top left, y down); the hook
// may run off the main thread, so it only takes this small lock.
typedef struct { uint32_t window; CGRect bounds; } DecorBounds;
enum { kMaxBounds = 256 };
static os_unfair_lock gBoundsLock = OS_UNFAIR_LOCK_INIT;
static DecorBounds gBounds[kMaxBounds];
static int gBoundsCount;

typedef const void *(*CopyFrameShapeFn)(CGXWindow *, int);
typedef const void *(*RegionWithRectFn)(CGRect);
typedef const void *(*RegionUnionFn)(const void *, const void *);
void *WXFDecorOrig_FrameShape;
static RegionWithRectFn gRegionWithRect;
static RegionUnionFn gRegionUnion;
typedef void (*InvalidateShadowFn)(CGXWindow *, CGXConnection *);
static InvalidateShadowFn gInvalidateShadow;      // CGXWindow::invalidate_shadow_and_schedule_update

typedef CGRect (*RegionBoundsFn)(const void *);
static RegionBoundsFn gRegionBounds;

// The window's shape's bounding box (window->shape, +0x180), the rect frame_bounds grows: screen points.
static CGRect ShapeBox(CGXWindow *w) {
    return (w->shape && gRegionBounds) ? gRegionBounds(w->shape) : WXFWindowGetFrame(w);
}

static CGRect DecorBoundsFor(CGXWindow *w) {
    CGRect bounds = CGRectNull;
    if (!gBoundsCount) return bounds;
    os_unfair_lock_lock(&gBoundsLock);
    for (int i = 0; i < gBoundsCount; i++)
        if (gBounds[i].window == w->window_id) { bounds = gBounds[i].bounds; break; }
    os_unfair_lock_unlock(&gBoundsLock);
    return bounds;
}

typedef CGRect (*FrameBoundsFn)(CGXWindow *);
void *WXFDecorOrig_FrameBounds;

CGRect WXFDecorHook_FrameBounds(CGXWindow *window) {
    CGRect r = ((FrameBoundsFn)WXFDecorOrig_FrameBounds)(window);
    if (!window) return r;
    CGRect bounds = DecorBoundsFor(window);
    if (CGRectIsNull(bounds)) return r;
    CGRect box = ShapeBox(window);
    return CGRectUnion(r, CGRectIntegral(CGRectOffset(bounds, box.origin.x, box.origin.y)));
}

static void PublishBounds(uint32_t window, CGRect bounds) {
    os_unfair_lock_lock(&gBoundsLock);
    int i = 0;
    while (i < gBoundsCount && gBounds[i].window != window) i++;
    if (CGRectIsNull(bounds)) {                          // remove
        if (i < gBoundsCount) gBounds[i] = gBounds[--gBoundsCount];
    } else if (i < gBoundsCount) {
        gBounds[i].bounds = bounds;
    } else if (gBoundsCount < kMaxBounds) {
        gBounds[gBoundsCount++] = (DecorBounds){ window, bounds };
    }
    os_unfair_lock_unlock(&gBoundsLock);
}

const void *WXFDecorHook_FrameShape(CGXWindow *window, int systemOffset) {
    const void *shape = ((CopyFrameShapeFn)WXFDecorOrig_FrameShape)(window, systemOffset);
    if (!window || !gBoundsCount || !gRegionWithRect || !gRegionUnion) return shape;
    CGRect bounds = DecorBoundsFor(window);
    if (CGRectIsNull(bounds)) return shape;
    CGRect frame = ShapeBox(window);
    CGRect rect = CGRectIntegral(CGRectOffset(bounds, frame.origin.x, frame.origin.y));
    if (systemOffset) {      // the original shifts by minus the system transform's translation (+0x528)
        const double *m = (const double *)&window->system_transform;
        rect = CGRectOffset(rect, -m[12], -m[13]);
    }
    const void *box = gRegionWithRect(rect);
    if (!box) return shape;
    const void *both = shape ? gRegionUnion(shape, box) : CFRetain(box);
    CFRelease(box);
    if (shape) CFRelease(shape);
    return both;
}

// The elements' bounds in window-local points, origin top left: what the hook adds.
static CGRect ElementBounds(WXFDElement *e, CGSize size) {
    const WXFDecorPlacement *pl = &e->placement;
    CGFloat w = pl->size.width + pl->stretch.width * size.width;
    CGFloat h = pl->size.height + pl->stretch.height * size.height;
    if (pl->size.width == 0 && pl->stretch.width == 0) w = e->natural.width;
    if (pl->size.height == 0 && pl->stretch.height == 0) h = e->natural.height;
    if (e->hidden || w <= 0 || h <= 0) return CGRectNull;
    CGFloat s = pl->scale != 0 ? pl->scale : 1;
    CGAffineTransform t = CGAffineTransformMakeTranslation(pl->windowAnchor.x * size.width + pl->offset.x,
                                                           pl->windowAnchor.y * size.height + pl->offset.y);
    t = CGAffineTransformRotate(t, pl->rotation);
    t = CGAffineTransformScale(t, s, s);
    t = CGAffineTransformTranslate(t, -pl->elementAnchor.x * w, -pl->elementAnchor.y * h);
    return CGRectApplyAffineTransform(CGRectMake(0, 0, w, h), t);
}

// --- Decors ---------------------------------------------------------------------------------
static WXFDDecor *DecorByID(WXFDecorID ident) {
    for (WXFDDecor *d in gDecors) if (d->ident == ident) return d;
    return nil;
}

static WXFDDecor *DecorForWindowID(CGWindowID window) {
    for (WXFDDecor *d in gDecors) if (d->windowID == window) return d;
    return nil;
}

static WXFDElement *ElementByID(WXFDecorElementID ident) {
    for (WXFDDecor *d in gDecors)
        for (WXFDElement *e in d->elements) if (e->ident == ident) return e;
    return nil;
}

static void *ContentOf(CGXWindow *w) {
    return w->window_type == 5 ? *(void **)((char *)w + kWindowContent) : NULL;
}

// The application behind a connection, as WindowServer itself looks it up: CGXGetConnectionAppName
// (its process record's name, CPXGetProcessName) and CPXCopyConnectionApplicationInformationItem
// (_LSCopyApplicationInformationItem for the record's application) with LaunchServices' keys.
typedef int (*ConnectionAppNameFn)(uint32_t, char *, size_t);
typedef CFTypeRef (*CopyAppInfoItemFn)(uint32_t, CFStringRef);
static ConnectionAppNameFn gConnectionAppName;
static CopyAppInfoItemFn gCopyAppInfoItem;
static CFStringRef gDisplayNameKey, gBundlePathKey;

static void CopyAppString(uint32_t connection, CFStringRef key, char *out, size_t size) {
    if (!gCopyAppInfoItem || !key) return;
    CFTypeRef v = gCopyAppInfoItem(connection, key);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, out, size, kCFStringEncodingUTF8);
    if (v) CFRelease(v);
}

static WXFDecorWindowInfo InfoFor(CGXWindow *w) {
    WXFDecorWindowInfo info = {0};
    info.window = w->window_id;
    info.frame = WXFWindowGetFrame(w);
    info.ownerConnectionID = WXFWindowGetOwnerConnectionID(w);
    info.cornerRadius = w->corner_radius;
    if (info.ownerConnectionID) {
        CopyAppString(info.ownerConnectionID, gDisplayNameKey, info.appName, sizeof info.appName);
        if (!info.appName[0] && gConnectionAppName)
            gConnectionAppName(info.ownerConnectionID, info.appName, sizeof info.appName);
        CopyAppString(info.ownerConnectionID, gBundlePathKey, info.bundlePath, sizeof info.bundlePath);
    }
    return info;
}

// The behind-container lives in the shadow layer (content+144), under the window (+160): the shadow
// layer has setPunchoutShadow:, which clears what is behind the window inside its own render, so a
// container behind the shadow layer showed the wallpaper through the window's translucent edge.
// It is placed so its coordinates are the root's. Inside CAScope.
static void PlaceBelowContainer(WXFDDecor *d) {
    if (!d->content) return;
    CALayer *root = (__bridge CALayer *)*(void **)((char *)d->content + kContentRoot);
    CALayer *frame = (__bridge CALayer *)*(void **)((char *)d->content + kContentFrame);
    if (root && frame) d->container[1].position = [frame convertPoint:CGPointZero fromLayer:root];
}

static void EnsureStarted(void);
static void EnsureTick(void);

// Puts the containers into the window's current tree (again, if the application was given a new
// context and the server rebuilt the tree). Inside CAScope.
static void InstallContainers(WXFDDecor *d, void *content) {
    CALayer *root = (__bridge CALayer *)*(void **)((char *)content + kContentRoot);
    id context = (__bridge id)*(void **)((char *)content + kContentContext);
    if (!root || !context) return;
    d->content = content;
    d->context = context;
    for (int i = 0; i < 2; i++) {
        if (!d->container[i]) {
            CALayer *c = [CALayer layer];
            c.anchorPoint = CGPointZero;
            c.position = CGPointZero;
            c.bounds = CGRectMake(0, 0, 1, 1);
            c.masksToBounds = NO;
            d->container[i] = c;
        }
        [d->container[i] removeFromSuperlayer];
    }
    CALayer *frame = (__bridge CALayer *)*(void **)((char *)content + kContentFrame);
    if (frame) [frame insertSublayer:d->container[1] atIndex:0];   // over the shadow, under the window
    else [root insertSublayer:d->container[1] atIndex:0];
    [root addSublayer:d->container[0]];                   // in front of everything the window has
    PlaceBelowContainer(d);
    for (WXFDElement *e in d->elements) {
        [d->container[e->below ? 1 : 0] addSublayer:e->layer];
        e->dirty = true;
    }
    d->dirty = true;
}

static WXFDDecor *AttachLocked(CGWindowID window) {
    EnsureStarted();
    if (!gAvailable) return nil;
    WXFDDecor *d = DecorForWindowID(window);
    if (d) return d;
    CGXWindow *target = WXFWindowFromID(window);
    void *content = target ? ContentOf(target) : NULL;
    if (!content) return nil;
    d = [WXFDDecor new];
    d->ident = gNextID++;
    d->windowID = window;
    d->target = target;
    d->elements = [NSMutableArray new];
    d->info = InfoFor(target);
    d->bounds = CGRectNull;
    [gDecors addObject:d];
    CAScope(^{ InstallContainers(d, content); });
    EnsureTick();
    os_log(Log(), "WXF decor: decor %u on window %u (%.0fx%.0f)", d->ident, window,
           d->info.frame.size.width, d->info.frame.size.height);
    return d;
}

// `windowAlive` false: the server has freed the window's tree; its context isn't committed again.
static void RemoveDecorLocked(WXFDDecor *d, bool windowAlive) {
    if (![gDecors containsObject:d]) return;
    if (!windowAlive) d->context = nil;
    CAScope(^{                             // the window's context still in the commit list here
        if (windowAlive) for (int i = 0; i < 2; i++) [d->container[i] removeFromSuperlayer];
        for (int i = 0; i < 2; i++) d->container[i] = nil;
        [d->elements removeAllObjects];
    });
    d->context = nil;
    PublishBounds(d->windowID, CGRectNull);
    [gDecors removeObject:d];
    os_log(Log(), "WXF decor: removed decor %u (window %u)", d->ident, d->windowID);
}

// --- Rules ----------------------------------------------------------------------------------
// An application's context is bound when it creates the window (_XCreateWindow), before the window
// is sized, levelled and ordered in, so a window that isn't decoratable yet may be later. Windows
// covering their whole display (login and full-screen backdrops) are left alone.
static bool Decoratable(CGXWindow *w) {
    if (w->window_type != 5 || w->level != 0 || w->screen_state == 0 || !w->connection || !ContentOf(w)) return false;
    CGRect frame = WXFWindowGetFrame(w);
    if (frame.size.width < 64 || frame.size.height < 48) return false;
    CGRect display = WXFDisplayGetBounds(WXFWindowGetDisplay(w));
    return CGRectIsEmpty(display) || !CGRectContainsRect(frame, display);
}

static void ProcessPending(void) {
    if (gTicks % 30 == 0 && gWaiting.count) {           // twice a second, look at the waiting ones again
        [gPending unionSet:gWaiting];
        [gWaiting removeAllObjects];
    }
    if (!gPending.count) return;
    NSArray<NSNumber *> *windows = [gPending allObjects];
    [gPending removeAllObjects];
    for (NSNumber *n in windows) {
        CGXWindow *w = WXFWindowFromID(n.unsignedIntValue);
        if (!w) continue;
        if (!Decoratable(w)) {
            [gWaiting addObject:n];
            continue;
        }
        WXFDecorWindowInfo info = InfoFor(w);
        NSMutableSet *done = gEvaluated[n];
        if (!done) gEvaluated[n] = done = [NSMutableSet new];
        for (WXFDRule *rule in [gRules copy]) {
            if ([done containsObject:@(rule->ident)]) continue;
            [done addObject:@(rule->ident)];
            if (rule->rule.match && !rule->rule.match(&info, rule->rule.userInfo)) continue;
            WXFDDecor *d = AttachLocked(n.unsignedIntValue);
            if (!d) break;
            if (!d->rules) d->rules = [NSMutableArray new];
            [d->rules addObject:rule];
            CAScope(^{ rule->rule.setup(d->ident, &info, rule->rule.userInfo); });
        }
    }
}

// --- Tick -----------------------------------------------------------------------------------
// Moves, raises, fades and transforms need nothing: the elements are in the window's tree. The tick
// lays elements out again when the window's size or corner radius changes or an element changed,
// follows the tree if the server rebuilt it, and drops decor whose window is gone.
static void Tick(void *info, double now) {
    (void)info; (void)now;
    Lock();
    gTickScheduled = false;
    ProcessPending();

    NSMutableArray<WXFDDecor *> *changed = [NSMutableArray new];
    for (WXFDDecor *d in [gDecors copy]) {
        CGXWindow *target = WXFWindowFromID(d->windowID);
        if (!target || target != d->target) {
            RemoveDecorLocked(d, false);
            continue;
        }
        void *content = ContentOf(target);
        if (!content) continue;
        CGRect frame = WXFWindowGetFrame(target);
        d->info.frame = frame;
        d->info.cornerRadius = target->corner_radius;
        bool rebuilt = content != d->content;
        bool resized = !CGSizeEqualToSize(frame.size, d->laidOutSize) || d->info.cornerRadius != d->laidOutRadius;
        d->sizeChanged = !CGSizeEqualToSize(d->laidOutSize, CGSizeZero) && !CGSizeEqualToSize(frame.size, d->laidOutSize);
        bool elementChanged = d->dirty;
        for (WXFDElement *e in d->elements) elementChanged |= e->dirty;
        if (rebuilt || resized || elementChanged) [changed addObject:d];
    }
    if (changed.count) {
        CAScope(^{
            for (WXFDDecor *d in changed) {
                void *content = ContentOf(d->target);
                if (content != d->content) InstallContainers(d, content);
                if (d->sizeChanged)
                    for (WXFDRule *rule in [d->rules copy])
                        if (rule->rule.resized) rule->rule.resized(d->ident, &d->info, rule->rule.userInfo);
                d->sizeChanged = false;
                PlaceBelowContainer(d);
                CGRect bounds = CGRectNull;
                for (WXFDElement *e in d->elements) {
                    ApplyLayer(e, d->info.frame.size, d->info.cornerRadius);
                    bounds = CGRectUnion(bounds, ElementBounds(e, d->info.frame.size));
                }
                if (!CGRectEqualToRect(bounds, d->bounds)) {
                    d->bounds = bounds;
                    d->boundsChanged = true;
                    PublishBounds(d->windowID, bounds);
                }
                d->laidOutSize = d->info.frame.size;
                d->laidOutRadius = d->info.cornerRadius;
                d->dirty = false;
            }
        });
        // The window's own context doesn't notify the server of commits (it is made with
        // WSCAContextServerOptionsDontNotify), so the window is marked changed, as a commit by its
        // application would.
        // New bounds: the frame shape and everything made from it are cached per window by its screen
        // geometry seed, so they are thrown away the way a shadow change does it (seed +1, shadow frame
        // invalidated, displays updated), and rebuilt through the hook.
        for (WXFDDecor *d in changed) {
            if (d->boundsChanged && gInvalidateShadow) gInvalidateShadow(d->target, d->target->connection);
            else WXFWindowUpdate(d->target);
            d->boundsChanged = false;
        }
    }

        if (++gTicks % 1800 == 0)
        for (NSNumber *key in [gEvaluated allKeys])
            if (!WXFWindowFromID(key.unsignedIntValue)) [gEvaluated removeObjectForKey:key];
    if (gDecors.count || gPending.count || gWaiting.count) EnsureTick();
    Unlock();
}

static void EnsureTick(void) {
    if (gTickScheduled) return;
    gTickScheduled = true;
    WXFScheduleCallback(Tick, NULL, WXFCurrentTime() + kTickInterval);
}

static void NewContextCallback(CGWindowID window, WXF_CAContextID context) {
    (void)context;
    Lock();
    if (gRules.count) {
        [gPending addObject:@(window)];
        EnsureTick();
    }
    Unlock();
}

static void EnsureStarted(void) {
    if (gStarted || !WXFIsFrameworkSetUp()) return;
    gStarted = true;
    gAvailable = WXFMiscIsAvailable(WXFMiscFeatureCore) && NSClassFromString(@"CAContext") != nil;
    gRegionWithRect = (RegionWithRectFn)dlsym(RTLD_DEFAULT, "CGRegionCreateWithRect");
    gRegionUnion = (RegionUnionFn)dlsym(RTLD_DEFAULT, "CGRegionCreateUnionWithRegion");
    gRegionBounds = (RegionBoundsFn)dlsym(RTLD_DEFAULT, "CGRegionGetBoundingBox");
    gConnectionAppName = (ConnectionAppNameFn)WXFResolveServerSymbol("_CGXGetConnectionAppName");
    gCopyAppInfoItem = (CopyAppInfoItemFn)WXFResolveServerSymbol("_CPXCopyConnectionApplicationInformationItem");
    CFStringRef *displayName = dlsym(RTLD_DEFAULT, "_kLSDisplayNameKey");
    CFStringRef *bundlePath = dlsym(RTLD_DEFAULT, "_kLSBundlePathKey");
    gDisplayNameKey = displayName ? *displayName : NULL;
    gBundlePathKey = bundlePath ? *bundlePath : NULL;
    gInvalidateShadow = (InvalidateShadowFn)WXFResolveServerSymbol(
        "__ZN9CGXWindow37invalidate_shadow_and_schedule_updateEP13CGXConnection");
    if (gAvailable && (!gRegionWithRect || !gRegionUnion || !WXFHooksInstall(WXFHookGroupDecor)))
        os_log(Log(), "WXF decor: no render bounds hooks; decor past the window's shadow will be cut off");
    os_log(Log(), "WXF decor: available %d", gAvailable);
}

// --- API ------------------------------------------------------------------------------------
#define LOCKED(...) InitState(); Lock(); __VA_ARGS__; Unlock();

bool WXFDecorIsAvailable(void) {
    InitState();
    Lock();
    EnsureStarted();
    bool r = gAvailable;
    Unlock();
    return r;
}

WXFDecorID WXFDecorAttach(CGWindowID window) {
    WXFDecorID r = 0;
    LOCKED(WXFDDecor *d = AttachLocked(window); r = d ? d->ident : 0)
    return r;
}

WXFDecorID WXFDecorForWindow(CGWindowID window) {
    WXFDecorID r = 0;
    LOCKED(WXFDDecor *d = DecorForWindowID(window); r = d ? d->ident : 0)
    return r;
}

CGWindowID WXFDecorGetWindow(WXFDecorID decor) {
    CGWindowID r = 0;
    LOCKED(WXFDDecor *d = DecorByID(decor); r = d ? d->windowID : 0)
    return r;
}

void WXFDecorRemove(WXFDecorID decor) {
    InitState();
    Lock();
    WXFDDecor *d = DecorByID(decor);
    if (d) RemoveDecorLocked(d, WXFWindowFromID(d->windowID) == d->target);
    Unlock();
}

void WXFDecorPerform(void (*work)(void *userInfo), void *userInfo) {
    if (!work) return;
    InitState();
    Lock();
    CAScope(^{ work(userInfo); });
    for (WXFDDecor *d in gDecors) d->dirty = true;     // whatever changed gets repainted
    EnsureTick();
    Unlock();
}

// Elements: all CA work inside CAScope; the next tick lays them out.
static WXFDecorElementID AddElement(WXFDecorID decor, CALayer *(^make)(CGSize *natural), WXFDecorPlacement placement,
                                    void (^configure)(WXFDElement *e)) {
    InitState();
    Lock();
    __block WXFDecorElementID r = 0;
    WXFDDecor *d = DecorByID(decor);
    if (d) CAScope(^{
        CGSize natural = CGSizeZero;
        CALayer *layer = make(&natural);
        if (!layer) return;
        WXFDElement *e = [WXFDElement new];
        e->ident = gNextID++;
        e->decor = d;
        e->layer = layer;
        e->natural = natural;
        e->placement = placement;
        if (e->placement.scale == 0) e->placement.scale = 1;
        e->opacity = 1;
        e->dirty = true;
        layer.hidden = YES;                               // until it is laid out
        if (configure) configure(e);
        [d->elements addObject:e];
        [d->container[e->below ? 1 : 0] addSublayer:layer];
        r = e->ident;
    });
    Unlock();
    return r;
}

WXFDecorElementID WXFDecorAddImage(WXFDecorID decor, CGImageRef image, CGFloat pixelsPerPoint, WXFDecorPlacement placement) {
    if (!image) return 0;
    CGFloat ppp = pixelsPerPoint > 0 ? pixelsPerPoint : 1;
    return AddElement(decor, ^CALayer *(CGSize *natural) {
        CALayer *layer = [CALayer layer];
        layer.contents = (__bridge id)image;
        layer.contentsScale = ppp;
        layer.contentsGravity = kCAGravityResize;
        *natural = CGSizeMake(CGImageGetWidth(image) / ppp, CGImageGetHeight(image) / ppp);
        return layer;
    }, placement, nil);
}

WXFDecorElementID WXFDecorAddRect(WXFDecorID decor, CGColorRef fill, CGColorRef border, CGFloat borderWidth,
                                  CGFloat cornerRadius, bool followWindowCorners, WXFDecorPlacement placement) {
    return AddElement(decor, ^CALayer *(CGSize *natural) {
        (void)natural;
        CALayer *layer = [CALayer layer];
        layer.backgroundColor = fill;
        layer.borderColor = border;
        layer.borderWidth = border ? borderWidth : 0;
        layer.cornerCurve = kCACornerCurveContinuous;
        return layer;
    }, placement, ^(WXFDElement *e) { e->baseRadius = cornerRadius; e->followCorners = followWindowCorners; });
}

WXFDecorElementID WXFDecorAddBorder(WXFDecorID decor, CGColorRef color, CGFloat width, CGFloat gap) {
    CGFloat out = gap + width;
    WXFDecorPlacement p = WXFDecorPlacementMake((CGPoint){0.5, 0.5}, (CGPoint){0.5, 0.5}, CGPointZero);
    p.size = CGSizeMake(2 * out, 2 * out);
    p.stretch = CGSizeMake(1, 1);
    return WXFDecorAddRect(decor, NULL, color, width, out, true, p);
}

WXFDecorElementID WXFDecorAddLayer(WXFDecorID decor, const void *layer, WXFDecorPlacement placement) {
    if (!layer) return 0;
    return AddElement(decor, ^CALayer *(CGSize *natural) {
        CALayer *l = (__bridge CALayer *)layer;
        *natural = l.bounds.size;
        return l;
    }, placement, nil);
}

void WXFDecorRemoveElement(WXFDecorElementID element) {
    InitState();
    Lock();
    CAScope(^{                            // looked up in here so the last reference dies in here
        WXFDElement *e = ElementByID(element);
        if (!e) return;
        [e->layer removeFromSuperlayer];
        e->decor->dirty = true;
        [e->decor->elements removeObject:e];
    });
    EnsureTick();
    Unlock();
}

const void *WXFDecorElementGetLayer(WXFDecorElementID element) {
    const void *r = NULL;
    LOCKED(WXFDElement *e = ElementByID(element); r = e ? (__bridge const void *)e->layer : NULL)
    return r;
}

void WXFDecorElementSetImage(WXFDecorElementID element, CGImageRef image) {
    if (!image) return;
    InitState();
    Lock();
    WXFDElement *e = ElementByID(element);
    if (e) {
        CAScope(^{ e->layer.contents = (__bridge id)image; });
        e->dirty = true;
    }
    Unlock();
}

void WXFDecorElementSetPlacement(WXFDecorElementID element, WXFDecorPlacement placement) {
    LOCKED(WXFDElement *e = ElementByID(element);
           if (e) { e->placement = placement; if (!e->placement.scale) e->placement.scale = 1; e->dirty = true; })
}

void WXFDecorElementSetOpacity(WXFDecorElementID element, float opacity) {
    LOCKED(WXFDElement *e = ElementByID(element); if (e) { e->opacity = MAX(0, MIN(1, opacity)); e->dirty = true; })
}

void WXFDecorElementSetHidden(WXFDecorElementID element, bool hidden) {
    LOCKED(WXFDElement *e = ElementByID(element); if (e) { e->hidden = hidden; e->dirty = true; })
}

void WXFDecorElementSetBelowWindow(WXFDecorElementID element, bool below) {
    InitState();
    Lock();
    WXFDElement *e = ElementByID(element);
    if (e && e->below != below) {
        e->below = below;
        e->dirty = true;
        CAScope(^{ [e->decor->container[below ? 1 : 0] addSublayer:e->layer]; });
    }
    Unlock();
}

WXFDecorRuleID WXFDecorAddRule(const WXFDecorRule *rule) {
    if (!rule || !rule->setup) return 0;
    InitState();
    Lock();
    EnsureStarted();
    uint32_t ident = 0;
    if (gAvailable) {
        if (!gRetriever) {
            gRetriever = WXFCAContextRetrieverCreate();
            if (!gRetriever || !WXFCAContextRetrieverRegisterNewContextCallback(gRetriever, NewContextCallback))
                os_log(Log(), "WXF decor: no CAContext retriever; rules won't see new windows");
        }
        WXFDRule *r = [WXFDRule new];
        r->ident = ident = gNextID++;
        r->rule = *rule;
        [gRules addObject:r];
        CFDictionaryRef all = gRetriever ? WXFCAContextRetrieverObtainContexts(gRetriever) : NULL;   // already open
        if (all) {
            for (NSNumber *window in (__bridge NSDictionary *)all) [gPending addObject:window];
            CFRelease(all);
        }
        EnsureTick();
    }
    Unlock();
    return ident;
}
