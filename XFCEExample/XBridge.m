//
//  XBridge.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// A Cocoa app's windows on XFCEExample's X session. Modeled on the AppKit bridge in
// ~/Developer/ceraina/bridge (there it is a Wayland client of KWin); here the "compositor" is the X
// server and its window manager (twm) and compositor (picom).
//
//   * Each NSWindow the app orders in gets an X window. The NSWindow stays on the Mac but is moved
//     behind the desktop picture, click-through, so the app keeps drawing it and the window server
//     keeps its pixels; the X window shows those pixels.
//   * Pixels come from the window server's own copy of the window (SLSHWCaptureWindowListToIOSurface-
//     Proxied, the private call under SLSHWCaptureWindowList), box-filtered from the backing scale
//     down to one pixel per point (the X screen is 1x), cropped of the AppKit title bar when twm
//     supplies one, and uploaded with PutImage -- only the rows that changed. Falls back to
//     rendering the view hierarchy.
//   * X input becomes NSEvents posted to the app (mouse, keys) or handed to the view (scroll), closing a window
//     in the window manager becomes -performClose:, resizing it resizes the NSWindow.
//
// Runs only in an app started with WXF_XBRIDGE=1 (XFCEExample/xfce-open.sh). Not handled yet:
// menus and popovers (separate NSWindows at popup levels, left native and so invisible), the app's
// menu bar, drag and drop, input methods.

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <os/log.h>
#include "XBridge.h"
#include "XBX11.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "WXF xbridge: " fmt, ##__VA_ARGS__)

static const void *kWindowKey = &kWindowKey;
static const double kFrameInterval = 1.0 / 30.0;
static const int kIdleTicksBeforeSlow = 45;     // ~1.5 s without a change
static const int kSlowTickEvery = 8;

// ── the window server's copy of the window ───────────────────────────────────────────────────────
// Same call and options as ceraina's bridge/window.m; see the comment there.
enum {
    kCaptureNominalResolution = 0x0200,
    kCaptureIgnoreGlobalClip = 0x0800,
    kCaptureAllowNonIntersecting = 0x8000,
};
#define CAPTURE_BGRA 0x42475241u   // 'BGRA', premultiplied, little-endian

typedef struct { int64_t v[4]; } CaptureOwner;
static int64_t (*p_captureSurface)(const CaptureOwner *, double, double, double, double, int64_t,
                                   CFArrayRef, int64_t, int64_t, mach_port_t *, char *);
static bool captureResolved;

static IOSurfaceRef CaptureWindowSurface(uint32_t number) {
    if (!captureResolved) {
        captureResolved = true;
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY);
        p_captureSurface = dlsym(RTLD_DEFAULT, "SLSHWCaptureWindowListToIOSurfaceProxied");
        if (!p_captureSurface && sky) p_captureSurface = dlsym(sky, "SLSHWCaptureWindowListToIOSurfaceProxied");
        LOG("window capture %{public}s", p_captureSurface ? "available" : "unavailable, rendering views");
    }
    if (!p_captureSurface || getenv("WXF_XBRIDGE_RENDER")) return NULL;
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 1, NULL);
    if (!list) return NULL;
    CFArrayAppendValue(list, (const void *)(uintptr_t)number);
    CaptureOwner owner = { { -1, -1, -1, -1 } };
    mach_port_t port = MACH_PORT_NULL;
    char failed = 0;
    int64_t status = p_captureSurface(&owner, 0, 0, 0, 0, 0, list,
                                      kCaptureNominalResolution | kCaptureIgnoreGlobalClip | kCaptureAllowNonIntersecting,
                                      0, &port, &failed);
    CFRelease(list);
    IOSurfaceRef surface = NULL;
    if (status == 0 && !(failed & 1) && port != MACH_PORT_NULL) surface = IOSurfaceLookupFromMachPort(port);
    if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
    return surface;
}

static CGWindowLevel HiddenLevel(void) {
    return CGWindowLevelForKey(kCGDesktopWindowLevelKey) - 1;
}

// ── one mirrored window ──────────────────────────────────────────────────────────────────────────
@interface XBWindow : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic) uint32_t xid;
@property(nonatomic) uint32_t gc;
@property(nonatomic) BOOL closing;
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)present:(BOOL)force;
- (void)applyXSize:(int)width height:(int)height;
- (CGFloat)cropTop;
- (void)noteActivity;
- (BOOL)isIdle;
- (void)syncMetadata;
- (void)teardown;
@end

static NSMutableDictionary<NSNumber *, XBWindow *> *gByXid;
static dispatch_source_t gReadSource, gTimer;
static NSUInteger gTick;
static int gWindowCount;

// The pointer, as the X server last said.
static struct {
    __weak XBWindow *hover;
    int button;                   // X button held, 0 none
    double lastClickTime;
    int lastClickX, lastClickY, clickCount;
} Pointer;

@implementation XBWindow {
    uint32_t *_cur, *_prev;
    size_t _capacity;
    int _xw, _xh;                 // the X window's size
    BOOL _needsFull;
    int _idleTicks;
    int _frames;
    int _hintMinW, _hintMinH, _hintMaxW, _hintMaxH;
    NSString *_title;
}

- (instancetype)initWithWindow:(NSWindow *)window {
    if (!(self = [super init])) return nil;
    _window = window;
    int w = (int)lround(window.frame.size.width);
    int h = (int)lround(window.frame.size.height - [self cropTop]);
    _xw = w < 1 ? 1 : w;
    _xh = h < 1 ? 1 : h;
    gWindowCount++;
    _xid = XBXCreateWindow(40 + 28 * (gWindowCount % 10), 60 + 28 * (gWindowCount % 10), _xw, _xh);
    _gc = XBXCreateGC(_xid);
    NSString *app = NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName;
    XBXSetClass(_xid, NSProcessInfo.processInfo.processName.UTF8String, app.UTF8String);
    XBXSetPid(_xid, (uint32_t)getpid());
    XBXSetDeleteProtocol(_xid);
    [self syncMetadata];
    XBXMapWindow(_xid);
    XBXFlush();
    _needsFull = YES;
    return self;
}

// Rows at the top of the NSWindow that the X window leaves out: the AppKit title bar, because the
// window manager draws one. Windows whose title bar holds a toolbar or content stay whole (their
// traffic lights are hidden instead).
- (CGFloat)cropTop {
    NSWindow *w = _window;
    if (!w) return 0;
    if (!(w.styleMask & NSWindowStyleMaskTitled) || (w.styleMask & NSWindowStyleMaskFullSizeContentView) || w.toolbar)
        return 0;
    CGFloat crop = w.frame.size.height - [w contentRectForFrameRect:w.frame].size.height;
    return crop > 0 ? crop : 0;
}

- (void)noteActivity { _idleTicks = 0; }
- (BOOL)isIdle { return _idleTicks > kIdleTicksBeforeSlow; }

// Title, class-independent hints: the window's size limits. Cheap; called now and then.
- (void)syncMetadata {
    NSWindow *w = _window;
    if (!w) return;
    NSString *title = w.title.length ? w.title : (NSProcessInfo.processInfo.processName ?: @"");
    if (![title isEqualToString:_title]) {
        _title = title;
        // WM_NAME is Latin-1 (twm complains about UTF-8 in it); _NET_WM_NAME carries the real title.
        NSData *ascii = [title dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
        NSString *legacy = ascii ? [[NSString alloc] initWithData:ascii encoding:NSISOLatin1StringEncoding] : title;
        XBXSetTitle(_xid, legacy.UTF8String, title.UTF8String);
    }
    CGFloat crop = [self cropTop];
    int minW = 0, minH = 0, maxW = 0, maxH = 0;
    if (w.styleMask & NSWindowStyleMaskResizable) {
        NSSize mn = w.minSize, mx = w.maxSize;
        NSSize cmn = w.contentMinSize, cmx = w.contentMaxSize;
        if (cmn.width > 0 || cmn.height > 0) {
            NSSize f = [w frameRectForContentRect:NSMakeRect(0, 0, cmn.width, cmn.height)].size;
            mn.width = fmax(mn.width, f.width);
            mn.height = fmax(mn.height, f.height);
        }
        minW = (int)ceil(mn.width);
        minH = (int)ceil(mn.height - crop);
        if (mx.width < 1e6 && mx.height < 1e6) { maxW = (int)floor(mx.width); maxH = (int)floor(mx.height - crop); }
        if (cmx.width > 0 && cmx.height > 0 && cmx.width < 1e6 && cmx.height < 1e6) {
            NSSize f = [w frameRectForContentRect:NSMakeRect(0, 0, cmx.width, cmx.height)].size;
            maxW = maxW ? (int)fmin(maxW, f.width) : (int)f.width;
            maxH = maxH ? (int)fmin(maxH, f.height - crop) : (int)(f.height - crop);
        }
    } else {
        minW = maxW = _xw;
        minH = maxH = _xh;
    }
    if (minW != _hintMinW || minH != _hintMinH || maxW != _hintMaxW || maxH != _hintMaxH) {
        _hintMinW = minW; _hintMinH = minH; _hintMaxW = maxW; _hintMaxH = maxH;
        XBXSetSizeHints(_xid, minW, minH, maxW, maxH);
    }
}

// The window manager (or the app) gave the X window this size: make the NSWindow match.
- (void)applyXSize:(int)width height:(int)height {
    NSWindow *w = _window;
    if (!w || width < 1 || height < 1 || (width == _xw && height == _xh)) return;
    _xw = width;
    _xh = height;
    NSRect old = w.frame;
    NSRect f = old;
    f.size = NSMakeSize(width, height + [self cropTop]);
    f.origin.y += old.size.height - f.size.height;   // keep the top-left corner where it was
    [w setFrame:f display:YES];
    _needsFull = YES;
    [self noteActivity];
}

// BGRX pixels of the window at one pixel per point, `out` w x h. False if nothing could be captured.
- (BOOL)captureInto:(uint32_t *)out width:(int)ow height:(int)oh crop:(CGFloat)crop {
    NSWindow *w = _window;
    IOSurfaceRef surface = CaptureWindowSurface((uint32_t)w.windowNumber);
    if (surface && IOSurfaceGetPixelFormat(surface) == CAPTURE_BGRA &&
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
        size_t sw = IOSurfaceGetWidth(surface), sh = IOSurfaceGetHeight(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface);
        const uint8_t *base = IOSurfaceGetBaseAddress(surface);
        double fw = w.frame.size.width;
        int s = (int)lround((double)sw / fw);
        if (s < 1) s = 1;
        int top = (int)lround(crop * s);
        bool fits = (size_t)ow * s <= sw && (size_t)(top + oh * s) <= sh;
        if (fits) {
            for (int y = 0; y < oh; y++) {
                const uint8_t *row = base + (size_t)(top + y * s) * stride;
                uint32_t *dst = out + (size_t)y * ow;
                if (s == 1) {
                    memcpy(dst, row, (size_t)ow * 4);
                } else if (s == 2) {
                    const uint8_t *row2 = row + stride;
                    for (int x = 0; x < ow; x++) {
                        const uint8_t *a = row + (size_t)x * 8, *b = row2 + (size_t)x * 8;
                        uint32_t c0 = (a[0] + a[4] + b[0] + b[4] + 2) >> 2;
                        uint32_t c1 = (a[1] + a[5] + b[1] + b[5] + 2) >> 2;
                        uint32_t c2 = (a[2] + a[6] + b[2] + b[6] + 2) >> 2;
                        dst[x] = c0 | c1 << 8 | c2 << 16;
                    }
                } else {
                    for (int x = 0; x < ow; x++) {
                        uint32_t sum[3] = {0, 0, 0};
                        for (int j = 0; j < s; j++)
                            for (int i = 0; i < s; i++) {
                                const uint8_t *p = row + (size_t)j * stride + (size_t)(x * s + i) * 4;
                                sum[0] += p[0]; sum[1] += p[1]; sum[2] += p[2];
                            }
                        uint32_t n = (uint32_t)(s * s);
                        dst[x] = (sum[0] / n) | (sum[1] / n) << 8 | (sum[2] / n) << 16;
                    }
                }
            }
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        CFRelease(surface);
        if (fits) return YES;
    } else if (surface) {
        CFRelease(surface);
    }

    // Fallback: draw the view hierarchy at one pixel per point.
    NSView *content = w.contentView;
    NSView *view = content.superview ?: content;
    int fw = (int)lround(w.frame.size.width), fh = (int)lround(w.frame.size.height);
    if (fw < 1 || fh < 1 || !view) return NO;
    uint32_t *full = calloc((size_t)fw * fh, 4);
    if (!full) return NO;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(full, fw, fh, 8, (size_t)fw * 4, rgb,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(rgb);
    if (!ctx) { free(full); return NO; }
    NSGraphicsContext *ns = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ns;
    [view displayRectIgnoringOpacity:view.bounds inContext:ns];
    [NSGraphicsContext restoreGraphicsState];
    CGContextFlush(ctx);
    CGContextRelease(ctx);
    int top = (int)lround(crop);
    for (int y = 0; y < oh && top + y < fh; y++)
        memcpy(out + (size_t)y * ow, full + (size_t)(top + y) * fw, (size_t)(ow < fw ? ow : fw) * 4);
    free(full);
    return YES;
}

- (void)present:(BOOL)force {
    NSWindow *w = _window;
    if (!w || _closing) return;
    if (w.level != HiddenLevel()) w.level = HiddenLevel();   // an app raising it must not show it on the Mac
    [w displayIfNeeded];
    CGFloat crop = [self cropTop];
    int ow = (int)lround(w.frame.size.width), oh = (int)lround(w.frame.size.height - crop);
    if (ow < 1 || oh < 1) return;
    if (ow != _xw || oh != _xh) {
        // The app resized itself (or refused a size the window manager asked for).
        XBXResizeWindow(_xid, ow, oh);
        _xw = ow;
        _xh = oh;
        _needsFull = YES;
    }
    size_t need = (size_t)ow * oh;
    if (need > _capacity) {
        free(_cur);
        free(_prev);
        _cur = calloc(need, 4);
        _prev = calloc(need, 4);
        _capacity = need;
        _needsFull = YES;
    }
    if (!_cur || !_prev) return;
    if (![self captureInto:_cur width:ow height:oh crop:crop]) return;

    int first = 0, last = oh - 1;
    if (!_needsFull && !force) {
        while (first <= last && memcmp(_cur + (size_t)first * ow, _prev + (size_t)first * ow, (size_t)ow * 4) == 0) first++;
        while (last >= first && memcmp(_cur + (size_t)last * ow, _prev + (size_t)last * ow, (size_t)ow * 4) == 0) last--;
    }
    if (first > last) {
        _idleTicks++;
        return;
    }
    _idleTicks = 0;
    _needsFull = NO;
    XBXPutImage(_xid, _gc, _cur + (size_t)first * ow, ow, first, last - first + 1);
    XBXFlush();
    // _cur is a whole frame and the rows outside first...last equal _prev's, so it is what the X window
    // shows now.
    uint32_t *t = _cur; _cur = _prev; _prev = t;
    if (++_frames == 1) LOG("first frame of \"%{public}s\" %dx%d", _title.UTF8String ?: "", ow, oh);
}

- (void)teardown {
    if (_closing) return;
    _closing = YES;
    if (_gc) XBXFreeGC(_gc);
    if (_xid) XBXDestroyWindow(_xid);
    XBXFlush();
    [gByXid removeObjectForKey:@(_xid)];
    free(_cur);
    free(_prev);
    _cur = _prev = NULL;
    _window = nil;
}

- (void)dealloc { free(_cur); free(_prev); }
@end

// ── tracking NSWindows ───────────────────────────────────────────────────────────────────────────
static XBWindow *BridgeFor(NSWindow *w) { return objc_getAssociatedObject(w, kWindowKey); }

static bool Bridgeable(NSWindow *w) {
    if (!w.contentView) return false;
    NSRect f = w.frame;
    if (f.size.width < 2 || f.size.height < 2) return false;
    // Menus, popovers, tool tips and other popup-level windows are positioned on the Mac's screen,
    // which the X server knows nothing about.
    if (w.level >= NSPopUpMenuWindowLevel) return false;
    // The desktop (Finder's icon window and the like) is the Mac's own; windows we hid behind it
    // carry HiddenLevel and may be ordered in again.
    if (w.level < 0 && w.level != HiddenLevel()) return false;
    return true;
}

static void HideOnMac(NSWindow *w) {
    // Behind the desktop picture: never visible, still drawn and captured. Not alpha 0 (the window
    // server multiplies it into the captured pixels) and not off screen (AppKit pulls it back).
    w.level = HiddenLevel();
    w.ignoresMouseEvents = YES;
    w.hasShadow = NO;
    w.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                            NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
    for (NSInteger b = NSWindowCloseButton; b <= NSWindowZoomButton; b++) [w standardWindowButton:b].hidden = YES;
}

static void TrackWindow(NSWindow *w) {
    if (BridgeFor(w) || !Bridgeable(w)) return;
    XBWindow *bw = [[XBWindow alloc] initWithWindow:w];
    objc_setAssociatedObject(w, kWindowKey, bw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gByXid[@(bw.xid)] = bw;
    HideOnMac(w);
    LOG("bridged \"%{public}s\" as X window 0x%x, %.0fx%.0f", w.title.UTF8String ?: "", bw.xid,
        w.frame.size.width, w.frame.size.height);
}

static void UntrackWindow(NSWindow *w) {
    XBWindow *bw = BridgeFor(w);
    if (!bw) return;
    LOG("closed \"%{public}s\" (X window 0x%x)", w.title.UTF8String ?: "", bw.xid);
    [bw teardown];
    objc_setAssociatedObject(w, kWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static IMP orig_makeKeyAndOrderFront, orig_orderFront, orig_orderFrontRegardless, orig_orderOut, orig_close, orig_orderWindow;

static void h_makeKeyAndOrderFront(NSWindow *self, SEL _cmd, id sender) {
    ((void (*)(id, SEL, id))orig_makeKeyAndOrderFront)(self, _cmd, sender);
    TrackWindow(self);
}
static void h_orderFront(NSWindow *self, SEL _cmd, id sender) {
    ((void (*)(id, SEL, id))orig_orderFront)(self, _cmd, sender);
    TrackWindow(self);
}
static void h_orderFrontRegardless(NSWindow *self, SEL _cmd) {
    ((void (*)(id, SEL))orig_orderFrontRegardless)(self, _cmd);
    TrackWindow(self);
}
static void h_orderOut(NSWindow *self, SEL _cmd, id sender) {
    UntrackWindow(self);
    ((void (*)(id, SEL, id))orig_orderOut)(self, _cmd, sender);
}
static void h_close(NSWindow *self, SEL _cmd) {
    UntrackWindow(self);
    ((void (*)(id, SEL))orig_close)(self, _cmd);
}

// The primitive the other ordering calls end in; also what window restoration uses.
static void h_orderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode mode, NSInteger other) {
    if (mode == NSWindowOut) UntrackWindow(self);
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))orig_orderWindow)(self, _cmd, mode, other);
    if (mode != NSWindowOut) TrackWindow(self);
}

static void Swizzle(SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(NSWindow.class, sel);
    if (m) *orig = method_setImplementation(m, imp);
}

// ── input: X events into NSEvents ────────────────────────────────────────────────────────────────
// Linux evdev key code (X keycode - 8) to Mac virtual key code; the table is ceraina's, plus the
// editing keys. Keys not listed (modifiers arrive in the event state) are dropped.
static const struct { uint16_t evdev, mac; } kKeys[] = {
    {1,53},{28,36},{15,48},{57,49},{14,51},{111,117},{102,115},{107,119},{104,116},{109,121},
    {103,126},{108,125},{105,123},{106,124},
    {2,18},{3,19},{4,20},{5,21},{6,23},{7,22},{8,26},{9,28},{10,25},{11,29},
    {16,12},{17,13},{18,14},{19,15},{20,17},{21,16},{22,32},{23,34},{24,31},{25,35},
    {30,0},{31,1},{32,2},{33,3},{34,5},{35,4},{36,38},{37,40},{38,37},
    {44,6},{45,7},{46,8},{47,9},{48,11},{49,45},{50,46},
    {59,122},{60,120},{61,99},{62,118},{63,96},{64,97},{65,98},{66,100},{67,101},{68,109},{87,103},{88,111},
    {12,27},{13,24},{26,33},{27,30},{43,42},{39,41},{40,39},{41,50},{51,43},{52,47},{53,44},
};

static int MacKeyForXKeycode(int keycode) {
    int evdev = keycode - 8;
    for (size_t i = 0; i < sizeof kKeys / sizeof kKeys[0]; i++)
        if (kKeys[i].evdev == evdev) return kKeys[i].mac;
    return -1;
}

static NSString *FunctionKeyCharacters(int mac) {
    unichar c = 0;
    switch (mac) {
        case 126: c = NSUpArrowFunctionKey; break;
        case 125: c = NSDownArrowFunctionKey; break;
        case 123: c = NSLeftArrowFunctionKey; break;
        case 124: c = NSRightArrowFunctionKey; break;
        case 117: c = NSDeleteFunctionKey; break;
        case 115: c = NSHomeFunctionKey; break;
        case 119: c = NSEndFunctionKey; break;
        case 116: c = NSPageUpFunctionKey; break;
        case 121: c = NSPageDownFunctionKey; break;
        case 122: c = NSF1FunctionKey; break;
        case 120: c = NSF2FunctionKey; break;
        case 99:  c = NSF3FunctionKey; break;
        case 118: c = NSF4FunctionKey; break;
        case 96:  c = NSF5FunctionKey; break;
        case 97:  c = NSF6FunctionKey; break;
        case 98:  c = NSF7FunctionKey; break;
        case 100: c = NSF8FunctionKey; break;
        case 101: c = NSF9FunctionKey; break;
        case 109: c = NSF10FunctionKey; break;
        case 103: c = NSF11FunctionKey; break;
        case 111: c = NSF12FunctionKey; break;
        case 36:  c = '\r'; break;
        case 48:  c = '\t'; break;
        case 53:  c = 0x1b; break;
        case 51:  c = 0x7f; break;
        default: return nil;
    }
    return [NSString stringWithCharacters:&c length:1];
}

static NSString *CharactersFor(int mac, NSEventModifierFlags mods) {
    NSString *special = FunctionKeyCharacters(mac);
    if (special) return special;
    TISInputSourceRef src = TISCopyCurrentKeyboardLayoutInputSource();
    if (!src) return nil;
    NSString *out = nil;
    CFDataRef data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData);
    if (data) {
        const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
        UInt32 mod = 0;
        if (mods & NSEventModifierFlagShift) mod |= shiftKey >> 8;
        if (mods & NSEventModifierFlagOption) mod |= optionKey >> 8;
        if (mods & NSEventModifierFlagControl) mod |= controlKey >> 8;
        UInt32 dead = 0;
        UniChar buf[8];
        UniCharCount n = 0;
        if (UCKeyTranslate(layout, (UInt16)mac, kUCKeyActionDown, mod, LMGetKbdType(),
                           kUCKeyTranslateNoDeadKeysMask, &dead, 8, &n, buf) == noErr && n > 0)
            out = [NSString stringWithCharacters:buf length:n];
    }
    CFRelease(src);
    return out;
}

static NSEventModifierFlags ModifiersFromState(uint16_t state) {
    NSEventModifierFlags m = 0;
    if (state & 1) m |= NSEventModifierFlagShift;
    if (state & 2) m |= NSEventModifierFlagCapsLock;
    if (state & 4) m |= NSEventModifierFlagControl;
    if (state & 8) m |= NSEventModifierFlagOption;      // Mod1 = Alt
    if (state & 64) m |= NSEventModifierFlagCommand;    // Mod4 = Super, which the tweak sends for Command
    return m;
}

// Window base coordinates (bottom-left origin, whole frame) of an X window point.
static NSPoint BasePoint(XBWindow *bw, int x, int y) {
    NSWindow *w = bw.window;
    return NSMakePoint(x, w.frame.size.height - [bw cropTop] - y);
}

// An AppKit mouse-down on a window that is not key is swallowed as an activation click unless the
// hit view accepts first mouse. The X server already decided which window the click is for.
static BOOL AcceptsFirstMouse(id self, SEL _cmd, NSEvent *event) { return YES; }

// Events go into the app's own queue, not straight to -sendEvent:. A control that tracks the mouse
// (text selection, buttons, sliders) sits in a nested event loop inside the mouse-down; the rest of
// the gesture has to be read from the X socket then, and a dispatch source cannot run again while its
// handler is still on the stack.
static void Post(NSEvent *event) { [NSApp postEvent:event atStart:NO]; }

static void DeliverMouse(XBWindow *bw, NSEventType type, const XBXEvent *e, int button) {
    NSWindow *w = bw.window;
    if (!w) return;
    NSPoint p = BasePoint(bw, e->x, e->y);
    int clicks = 0;
    if (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown || type == NSEventTypeOtherMouseDown) {
        double now = CACurrentMediaTime();
        if (now - Pointer.lastClickTime < 0.4 && abs(e->x - Pointer.lastClickX) < 5 && abs(e->y - Pointer.lastClickY) < 5)
            Pointer.clickCount++;
        else
            Pointer.clickCount = 1;
        Pointer.lastClickTime = now;
        Pointer.lastClickX = e->x;
        Pointer.lastClickY = e->y;
        clicks = Pointer.clickCount;
    } else if (type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp || type == NSEventTypeOtherMouseUp) {
        clicks = Pointer.clickCount;
    }
    NSEvent *event = [NSEvent mouseEventWithType:type location:p modifierFlags:ModifiersFromState(e->state)
                                       timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:clicks
                                        pressure:(type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseDragged) ? 1.0 : 0.0];
    if (event) Post(event);
}

static void DeliverScroll(XBWindow *bw, const XBXEvent *e) {
    NSWindow *w = bw.window;
    if (!w) return;
    // X buttons 4/5 are vertical, 6/7 horizontal; one notch is a few lines.
    int dy = 0, dx = 0;
    switch (e->detail) {
        case 4: dy = 40; break;
        case 5: dy = -40; break;
        case 6: dx = 40; break;
        case 7: dx = -40; break;
    }
    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, dy, dx);
    if (!cg) return;
    NSPoint base = BasePoint(bw, e->x, e->y);
    NSEvent *event = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    if (!event) return;
    // A scroll event made from a CGEvent has no window (it is placed by screen position, and the
    // window is hidden), so AppKit could not route it: find the view under the pointer and hand it
    // the event. Views pass -scrollWheel: up the responder chain to their scroll view.
    NSView *content = w.contentView;
    NSPoint inParent = [content.superview convertPoint:base fromView:nil];
    NSView *hit = [content hitTest:inParent] ?: content;
    [hit scrollWheel:event];
}

static void DeliverKey(XBWindow *bw, const XBXEvent *e, bool down) {
    NSWindow *w = bw.window;
    if (!w) return;
    int mac = MacKeyForXKeycode(e->detail);
    if (mac < 0) return;
    NSEventModifierFlags mods = ModifiersFromState(e->state);
    NSString *chars = CharactersFor(mac, mods) ?: @"";
    NSString *plain = CharactersFor(mac, mods & NSEventModifierFlagShift) ?: chars;
    NSEvent *event = [NSEvent keyEventWithType:(down ? NSEventTypeKeyDown : NSEventTypeKeyUp) location:NSZeroPoint
                                 modifierFlags:mods timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:w.windowNumber context:nil characters:chars
                   charactersIgnoringModifiers:plain isARepeat:NO keyCode:(unsigned short)mac];
    if (!event) return;
    Post(event);   // a Command shortcut finds the main menu on its way, as it would natively
}

static void HandleEvent(const XBXEvent *e) {
    XBWindow *bw = gByXid[@(e->window)];
    static int logged;
    if (e->type != XBXMotionNotify && e->type != XBXExpose && logged < 40) {
        logged++;
        LOG("X event %d window 0x%x detail %d at (%d, %d) %{public}s", e->type, e->window, e->detail, e->x, e->y,
            bw ? "bridged" : "unknown window");
    }
    if (!bw || bw.closing || !bw.window) return;
    [bw noteActivity];
    switch (e->type) {
        case XBXExpose:
            if (e->width && e->height) [bw present:YES];
            break;
        case XBXConfigureNotify:
            [bw applyXSize:e->width height:e->height];
            break;
        case XBXClientMessage:
            if (e->atom == XBXAtomWMProtocols && e->data0 == XBXAtomWMDeleteWindow) {
                NSWindow *w = bw.window;
                if (w.styleMask & NSWindowStyleMaskClosable) [w performClose:nil]; else [w close];
            }
            break;
        case XBXFocusIn:
            [bw.window makeKeyWindow];
            [bw.window makeMainWindow];
            break;
        case XBXEnterNotify:
            Pointer.hover = bw;
            break;
        case XBXLeaveNotify:
            if (Pointer.hover == bw) Pointer.hover = nil;
            break;
        case XBXMotionNotify: {
            NSEventType type = NSEventTypeMouseMoved;
            if (Pointer.button == 1) type = NSEventTypeLeftMouseDragged;
            else if (Pointer.button == 3) type = NSEventTypeRightMouseDragged;
            else if (Pointer.button) type = NSEventTypeOtherMouseDragged;
            DeliverMouse(bw, type, e, 0);
            break;
        }
        case XBXButtonPress:
            if (e->detail >= 4 && e->detail <= 7) { DeliverScroll(bw, e); break; }
            Pointer.button = e->detail;
            DeliverMouse(bw, e->detail == 1 ? NSEventTypeLeftMouseDown : e->detail == 3 ? NSEventTypeRightMouseDown
                                                                                         : NSEventTypeOtherMouseDown, e, e->detail);
            break;
        case XBXButtonRelease:
            if (e->detail >= 4 && e->detail <= 7) break;
            if (Pointer.button == e->detail) Pointer.button = 0;
            DeliverMouse(bw, e->detail == 1 ? NSEventTypeLeftMouseUp : e->detail == 3 ? NSEventTypeRightMouseUp
                                                                                       : NSEventTypeOtherMouseUp, e, e->detail);
            break;
        case XBXKeyPress:
            DeliverKey(bw, e, true);
            break;
        case XBXKeyRelease:
            DeliverKey(bw, e, false);
            break;
    }
}

// ── the loop ─────────────────────────────────────────────────────────────────────────────────────
static void XServerGone(void) {
    if (gReadSource) { dispatch_source_cancel(gReadSource); gReadSource = NULL; }
    LOG("the X server went away; quitting");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
    if (NSApp) [NSApp terminate:nil]; else exit(0);
}

// Windows can appear or go away by routes the ordering hooks miss (restoration, an app flipping
// -setIsVisible:), so the app's window list is checked now and then too.
static void ScanWindows(void) {
    for (NSWindow *w in [NSApp.windows copy]) {
        XBWindow *bw = BridgeFor(w);
        if (!bw && w.isVisible && !w.isMiniaturized) TrackWindow(w);
        else if (bw && !w.isVisible) UntrackWindow(w);
    }
}

static void Tick(void) {
    gTick++;
    if (NSApp && gTick % 15 == 0) ScanWindows();
    for (XBWindow *bw in [gByXid.allValues copy]) {
        if (bw.closing || !bw.window) continue;
        if ([bw isIdle] && gTick % kSlowTickEvery != 0) continue;
        [bw present:NO];
        if (gTick % 30 == 0) [bw syncMetadata];
    }
    XBXFlush();
}

void XBridgeStart(void) {
    static bool started;
    if (started || !getenv("WXF_XBRIDGE")) return;   // or an app that was not started for the X session
    started = true;
    @autoreleasepool {
        if (!XBXConnect()) {
            LOG("no X server: %{public}s; running on the Mac", XBXLastError());
            return;
        }
        gByXid = [NSMutableDictionary dictionary];
        XBXScreen screen = XBXGetScreen();
        LOG("connected to X, screen %ux%u in pid %d", screen.width, screen.height, getpid());

        Method first = class_getInstanceMethod(NSView.class, @selector(acceptsFirstMouse:));
        if (first) method_setImplementation(first, (IMP)AcceptsFirstMouse);
        Swizzle(@selector(makeKeyAndOrderFront:), (IMP)h_makeKeyAndOrderFront, &orig_makeKeyAndOrderFront);
        Swizzle(@selector(orderFront:), (IMP)h_orderFront, &orig_orderFront);
        Swizzle(@selector(orderFrontRegardless), (IMP)h_orderFrontRegardless, &orig_orderFrontRegardless);
        Swizzle(@selector(orderOut:), (IMP)h_orderOut, &orig_orderOut);
        Swizzle(@selector(close), (IMP)h_close, &orig_close);
        Swizzle(@selector(orderWindow:relativeTo:), (IMP)h_orderWindow, &orig_orderWindow);

        gReadSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)XBXFd(), 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(gReadSource, ^{
            if (!XBXReadEvents(^(const XBXEvent *e) { HandleEvent(e); })) XServerGone();
            XBXFlush();
        });
        dispatch_resume(gReadSource);

        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFrameInterval * NSEC_PER_SEC)),
                                  (uint64_t)(kFrameInterval * NSEC_PER_SEC), NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{ Tick(); });
        dispatch_resume(gTimer);
    }
}

// Loading the dylib is enough when it is inserted (DYLD_INSERT_LIBRARIES, which xfce-open.sh --inject
// does for apps the tweak's whitelist doesn't name); the tweak calls XBridgeStart itself otherwise.
__attribute__((constructor))
static void XBridgeLoaded(void) { XBridgeStart(); }
