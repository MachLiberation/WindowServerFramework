//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// A knockoff of niri, the scrolling tiling window manager, as a custom Exposé that never goes
// away. Windows sit in columns on an endless strip that scrolls sideways; the focused column is
// kept in the middle and every column is as tall as the screen. Windows of one application start in
// one column, stacked. The strip is always on: it begins when WindowServer has windows, follows
// windows opening and closing, and input goes through to the windows where they are drawn.
//
// "Mod" is Control+Option, so plain keys and clicks keep working in the applications.
//
//   Mod + left / right, h / l   focus the previous / next column
//   Mod + up / down, k / j      focus the window above / below inside a column
//   Mod + Shift + those         move the column (or the window within its column)
//   Mod + , (comma)             pull the focused window into the column on its left
//   Mod + . (period)            push the focused window out into a column of its own
//   Mod + R                     cycle the column width: fit height, 1/3, 1/2, 2/3 of the screen
//   Mod + Tab                   overview: zoom the whole strip out, again to zoom back in
//   Mod + N                     turn the strip off / on (control+option+command+escape also turns it off)
//   swipe sideways              (the Spaces swipe) scrolls the strip with the fingers
//   swipe up / down             overview on / off
//   dragging a title bar        does nothing: the strip decides where windows go
//   a click                     focuses that window's column (in the overview it also zooms back in)
//
// The strip is pure transforms: windows are scaled to fit their column, not resized, and go back
// exactly where they were when it is turned off. The framework's part is the window list, the
// transforms, the frame clock, activation and passing input through; this file is the column model
// (Column), the layout (Layout) and the input (HandleEvent).

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/WXFEvent.h>
#include <WindowServerFramework/WXFExpose.h>
#include <Foundation/Foundation.h>
#include <math.h>
#include <os/log.h>

enum {
    kVKTab = 48, kVKComma = 43, kVKPeriod = 47,
    kVKH = 4, kVKJ = 38, kVKK = 40, kVKL = 37, kVKN = 45, kVKR = 15,
    kVKLeftArrow = 123, kVKRightArrow = 124, kVKDownArrow = 125, kVKUpArrow = 126,
};

static const double kGap = 16.0;            // between windows and columns, and around the strip
static const double kTopInset = 32.0;       // keeps the strip below the menu bar
static const double kOverviewZoom = 0.45;
static const double kIntro = 0.3;           // seconds to fly in or out
static const double kStiffness = 120.0;     // the spring that carries the strip to the focused column
static const double kDamping = 2.0 * 11.0;  // about critical for that stiffness
static const double kReshape = 14.0;        // how fast column widths settle (1/s)
static const double kPoll = 0.5;            // seconds between looks for opened / closed windows

// A sideways swipe of progress 1 scrolls this many columns; the sign is whichever way the fingers
// went when the strip should move left (a guess, to be read off the log of a live test).
static const double kSwipeColumns = 3.0;
static const double kSwipeRightSign = -1.0;
static const double kSwipeCommit = 0.2;     // vertical swipe distance that toggles the overview

// Column width presets, as a fraction of the screen width; 0 fits the screen height.
static const double kWidthPreset[] = { 0, 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0 };
#define kWidthPresets (sizeof(kWidthPreset) / sizeof(kWidthPreset[0]))

// One column of the strip. `windows` holds window ids, top to bottom.
@interface Column : NSObject
@property NSMutableArray<NSNumber *> *windows;
@property NSUInteger focusRow;
@property NSUInteger widthMode;
@property double fit;               // animated scale applied to the column's windows
@end
@implementation Column
@end

static struct {
    NSMutableArray<Column *> *columns;
    NSMutableDictionary<NSNumber *, NSNumber *> *itemOf;    // window id -> item index
    NSUInteger focus;       // the focused column
    double position;        // which column is in the middle, fractional while the strip moves
    double velocity;
    double drag;            // columns the fingers have scrolled the strip, during a swipe
    double progress;        // 0 = windows where they were, 1 = strip
    double overview;        // 0 = strip at full size, 1 = zoomed out
    bool overviewOn;
    bool enabled;           // the strip should be up whenever there are windows
} gNiri;

static struct {
    bool tracking;
    WXFEventSwipeMotion motion;
} gSwipe;

static bool gSuppressDrag;  // a click began in a title bar: its drag would move a window of the strip
static const double kTitleBar = 40.0;      // points, at natural size

static bool gKeyDown[128];  // keys we consumed, whose release we consume too
static WXFExposeProviderRef gProvider;

static float Smooth(double t) {
    t = fmin(fmax(t, 0), 1);
    return (float)(t * t * (3 - 2 * t));
}

static float Lerp(float a, float b, float t) { return a + (b - a) * t; }

static WXFExposeItemRef ItemOf(WXFExposeSessionRef s, NSNumber *windowID) {
    NSNumber *i = gNiri.itemOf[windowID];
    return i ? WXFExposeSessionGetItemAtIndex(s, i.integerValue) : NULL;
}

static CGRect FrameOf(WXFExposeSessionRef s, NSNumber *windowID) {
    WXFExposeItemRef item = ItemOf(s, windowID);
    return item ? WXFExposeItemGetFrame(item) : CGRectZero;
}

// MARK: Column geometry

// The scale at which the column's windows stacked fill `height`, and the widest window of the column.
static double HeightFit(WXFExposeSessionRef s, Column *c, double height, double *widest) {
    double stack = 0, wide = 1;
    for (NSNumber *n in c.windows) {
        CGRect f = FrameOf(s, n);
        stack += f.size.height;
        wide = fmax(wide, f.size.width);
    }
    if (widest) *widest = wide;
    double room = height - kGap * ((double)c.windows.count - 1);
    return fmax(0.05, fmin(1.0, room / fmax(stack, 1)));
}

// Where the column's scale is headed: its windows fill the strip's height, narrowed if the width
// preset asks for less.
static double TargetFit(WXFExposeSessionRef s, Column *c, CGRect bounds) {
    double height = bounds.size.height - kTopInset - 2 * kGap, wide;
    double fit = HeightFit(s, c, height, &wide);
    double fraction = kWidthPreset[c.widthMode];
    if (fraction > 0) fit = fmin(fit, bounds.size.width * fraction / wide);
    return fit;
}

static double ColumnWidth(WXFExposeSessionRef s, Column *c) {
    double wide = 0;
    for (NSNumber *n in c.windows) wide = fmax(wide, FrameOf(s, n).size.width);
    return wide * c.fit;
}

// Centre of column `i`, measured along the strip from its start.
static double ColumnCenter(WXFExposeSessionRef s, long i) {
    double x = kGap;
    for (long j = 0; j < i; j++) x += ColumnWidth(s, gNiri.columns[j]) + kGap;
    return x + ColumnWidth(s, gNiri.columns[i]) / 2;
}

// MARK: Model

static Column *Focused(void) { return gNiri.columns[gNiri.focus]; }

static NSNumber *FocusedWindow(void) {
    Column *c = Focused();
    return c.windows[c.focusRow];
}

static void ActivateFocused(WXFExposeSessionRef s) {
    WXFExposeItemRef item = ItemOf(s, FocusedWindow());
    if (item) WXFExposeSessionActivateItem(s, item);
}

static void FocusColumn(WXFExposeSessionRef s, long to) {
    gNiri.focus = (NSUInteger)MIN(MAX(to, 0), (long)gNiri.columns.count - 1);
    ActivateFocused(s);
    WXFExposeSessionSetNeedsLayout(s);
}

static void FocusRow(WXFExposeSessionRef s, long to) {
    Column *c = Focused();
    c.focusRow = (NSUInteger)MIN(MAX(to, 0), (long)c.windows.count - 1);
    ActivateFocused(s);
    WXFExposeSessionSetNeedsLayout(s);
}

static void MoveColumn(WXFExposeSessionRef s, long by) {
    long to = (long)gNiri.focus + by;
    if (to < 0 || to >= (long)gNiri.columns.count) return;
    [gNiri.columns exchangeObjectAtIndex:gNiri.focus withObjectAtIndex:(NSUInteger)to];
    gNiri.focus = (NSUInteger)to;
    WXFExposeSessionSetNeedsLayout(s);
}

static void MoveRow(WXFExposeSessionRef s, long by) {
    Column *c = Focused();
    long to = (long)c.focusRow + by;
    if (to < 0 || to >= (long)c.windows.count) return;
    [c.windows exchangeObjectAtIndex:c.focusRow withObjectAtIndex:(NSUInteger)to];
    c.focusRow = (NSUInteger)to;
    WXFExposeSessionSetNeedsLayout(s);
}

// Drops empty columns and keeps the focus in range.
static void Tidy(void) {
    NSMutableArray<Column *> *keep = [NSMutableArray array];
    for (Column *c in gNiri.columns) if (c.windows.count) [keep addObject:c];
    gNiri.columns = keep;
    if (!keep.count) return;
    gNiri.focus = MIN(gNiri.focus, keep.count - 1);
    for (Column *c in keep) c.focusRow = MIN(c.focusRow, c.windows.count - 1);
}

// Niri's consume-or-expel: the focused window joins the column on its left ...
static void ConsumeLeft(WXFExposeSessionRef s) {
    if (gNiri.focus == 0) return;
    Column *from = Focused(), *into = gNiri.columns[gNiri.focus - 1];
    NSNumber *n = from.windows[from.focusRow];
    [from.windows removeObjectAtIndex:from.focusRow];
    [into.windows addObject:n];
    into.focusRow = into.windows.count - 1;
    gNiri.focus -= 1;
    Tidy();
    WXFExposeSessionSetNeedsLayout(s);
}

// ... or leaves its column for one of its own on the right.
static void ExpelRight(WXFExposeSessionRef s) {
    Column *from = Focused();
    if (from.windows.count < 2) return;
    NSNumber *n = from.windows[from.focusRow];
    [from.windows removeObjectAtIndex:from.focusRow];
    Column *c = [Column new];
    c.windows = [NSMutableArray arrayWithObject:n];
    c.fit = from.fit;
    [gNiri.columns insertObject:c atIndex:gNiri.focus + 1];
    gNiri.focus += 1;
    Tidy();
    WXFExposeSessionSetNeedsLayout(s);
}

static void CycleWidth(WXFExposeSessionRef s) {
    Column *c = Focused();
    c.widthMode = (c.widthMode + 1) % kWidthPresets;
    WXFExposeSessionSetNeedsLayout(s);
}

static void SetOverview(WXFExposeSessionRef s, bool on) {
    gNiri.overviewOn = on;
    WXFExposeSessionSetNeedsLayout(s);
}

// MARK: Provider

static void IndexItems(WXFExposeSessionRef session) {
    gNiri.itemOf = [NSMutableDictionary dictionary];
    for (long i = 0, n = WXFExposeSessionGetItemCount(session); i < n; i++)
        gNiri.itemOf[@(WXFExposeItemGetWindowID(WXFExposeSessionGetItemAtIndex(session, i)))] = @(i);
}

// Brings the columns in line with the session's windows: those that closed leave, new ones join
// the column of their application (or get one of their own after the focused column).
static void SyncColumns(WXFExposeSessionRef session) {
    IndexItems(session);
    CGRect bounds = WXFExposeSessionGetBounds(session);
    NSMutableSet<NSNumber *> *placed = [NSMutableSet set];
    for (Column *c in gNiri.columns) {
        NSMutableArray *alive = [NSMutableArray array];
        for (NSNumber *w in c.windows) if (gNiri.itemOf[w]) { [alive addObject:w]; [placed addObject:w]; }
        c.windows = alive;
    }
    for (long i = 0, n = WXFExposeSessionGetItemCount(session); i < n; i++) {
        WXFExposeItemRef item = WXFExposeSessionGetItemAtIndex(session, i);
        NSNumber *w = @(WXFExposeItemGetWindowID(item));
        if ([placed containsObject:w]) continue;
        // Same application as a window already in a column?
        Column *home = nil;
        for (Column *c in gNiri.columns)
            if (c.windows.count && WXFExposeItemGetOwnerID(ItemOf(session, c.windows[0])) == WXFExposeItemGetOwnerID(item)) {
                home = c;
                break;
            }
        if (home) {
            [home.windows addObject:w];
        } else {
            Column *c = [Column new];
            c.windows = [NSMutableArray arrayWithObject:w];
            c.fit = 1;
            [gNiri.columns insertObject:c atIndex:gNiri.columns.count ? gNiri.focus + 1 : 0];
        }
        [placed addObject:w];
    }
    Tidy();
    for (Column *c in gNiri.columns) if (c.fit == 1 || c.fit == 0) c.fit = TargetFit(session, c, bounds);
}

static void DidBegin(WXFExposeSessionRef session, void *info) {
    (void)info;
    // Frontmost window first, so the strip opens focused on it.
    gNiri.columns = [NSMutableArray array];
    gNiri.focus = 0;
    SyncColumns(session);
    gNiri.position = 0;
    gNiri.velocity = 0;
    gNiri.drag = 0;
    gNiri.progress = 0;
    gNiri.overview = 0;
    gNiri.overviewOn = false;
    // Open on the column holding the frontmost window (item 0).
    NSNumber *front = @(WXFExposeItemGetWindowID(WXFExposeSessionGetItemAtIndex(session, 0)));
    for (NSUInteger ci = 0; ci < gNiri.columns.count; ci++) {
        NSUInteger r = [gNiri.columns[ci].windows indexOfObject:front];
        if (r != NSNotFound) { gNiri.focus = ci; gNiri.columns[ci].focusRow = r; }
    }
    gNiri.position = (double)gNiri.focus;
    os_log(OS_LOG_DEFAULT, "WXF niri: %ld windows in %lu columns", WXFExposeSessionGetItemCount(session),
           (unsigned long)gNiri.columns.count);
}

static void DidReload(WXFExposeSessionRef session, void *info) {
    (void)info;
    NSNumber *keep = gNiri.columns.count ? FocusedWindow() : nil;
    SyncColumns(session);
    // Keep the focus on the window that had it, if it is still there.
    for (NSUInteger ci = 0; keep && ci < gNiri.columns.count; ci++) {
        NSUInteger r = [gNiri.columns[ci].windows indexOfObject:keep];
        if (r != NSNotFound) { gNiri.focus = ci; gNiri.columns[ci].focusRow = r; }
    }
    os_log(OS_LOG_DEFAULT, "WXF niri: reloaded, %lu columns", (unsigned long)gNiri.columns.count);
}

static bool Layout(WXFExposeSessionRef session, const WXFExposeFrame *frame, void *info) {
    (void)info;
    double dt = fmin(frame->delta, 1.0 / 30.0);
    CGRect bounds = frame->bounds;
    if (!gNiri.columns.count) return false;

    // The strip follows the focused column (plus the fingers' scroll) with a damped spring.
    double goal = (double)gNiri.focus + gNiri.drag;
    double accel = kStiffness * (goal - gNiri.position) - kDamping * gNiri.velocity;
    gNiri.velocity += accel * dt;
    gNiri.position += gNiri.velocity * dt;
    bool moving = fabs(goal - gNiri.position) > 0.0005 || fabs(gNiri.velocity) > 0.001;
    if (!moving) {
        gNiri.position = goal;
        gNiri.velocity = 0;
    }

    gNiri.progress += (frame->ending ? -dt : dt) / kIntro;
    gNiri.progress = fmin(fmax(gNiri.progress, 0), 1);
    float t = Smooth(gNiri.progress);

    double ovTarget = (gNiri.overviewOn && !frame->ending) ? 1 : 0;
    gNiri.overview += (ovTarget - gNiri.overview) * (1 - exp(-dt * 12));
    bool zooming = fabs(ovTarget - gNiri.overview) > 0.002;
    if (!zooming) gNiri.overview = ovTarget;
    double zoom = 1 + (kOverviewZoom - 1) * gNiri.overview;

    // Column widths settle toward their targets.
    bool reshaping = false;
    for (Column *c in gNiri.columns) {
        double target = TargetFit(session, c, bounds);
        c.fit += (target - c.fit) * (1 - exp(-dt * kReshape));
        if (fabs(target - c.fit) > 0.0005) reshaping = true; else c.fit = target;
    }

    // The strip position that is centred: between the columns the position falls between.
    long count = (long)gNiri.columns.count;
    double p = fmin(fmax(gNiri.position, 0), (double)count - 1);
    long lo = (long)floor(p), hi = MIN(lo + 1, count - 1);
    double middle = ColumnCenter(session, lo) + (ColumnCenter(session, hi) - ColumnCenter(session, lo)) * (p - (double)lo);
    double stripMid = kTopInset + (bounds.size.height - kTopInset) / 2;
    double screenMidX = CGRectGetMidX(bounds), screenMidY = CGRectGetMidY(bounds);

    for (long ci = 0; ci < count; ci++) {
        Column *c = gNiri.columns[ci];
        double x = ColumnCenter(session, ci) - middle;
        double stack = 0;
        for (NSNumber *n in c.windows) stack += FrameOf(session, n).size.height * c.fit;
        stack += kGap * ((double)c.windows.count - 1);
        double y = stripMid - stack / 2;        // top of the next window in the column

        for (NSUInteger r = 0; r < c.windows.count; r++) {
            WXFExposeItemRef item = ItemOf(session, c.windows[r]);
            CGRect f = WXFExposeItemGetFrame(item);
            double h = f.size.height * c.fit;

            // Strip coordinates relative to the screen centre, then zoomed for the overview.
            CGPoint center = CGPointMake(screenMidX + x * zoom, screenMidY + (y + h / 2 - screenMidY) * zoom);
            double scale = c.fit * zoom;

            WXFExposeItemLayout l = {0};
            l.center = CGPointMake(Lerp(CGRectGetMidX(f), center.x, t), Lerp(CGRectGetMidY(f), center.y, t));
            l.scale = CGSizeMake(Lerp(1, scale, t), Lerp(1, scale, t));
            l.alpha = 1;
            WXFExposeItemSetLayout(item, &l);
            y += h + kGap;
        }
    }

    if (frame->ending) return gNiri.progress > 0;
    return moving || zooming || reshaping || gNiri.progress < 1;
}

static void FocusWindow(WXFExposeSessionRef s, NSNumber *windowID) {
    for (NSUInteger ci = 0; ci < gNiri.columns.count; ci++) {
        Column *c = gNiri.columns[ci];
        NSUInteger r = [c.windows indexOfObject:windowID];
        if (r == NSNotFound) continue;
        gNiri.focus = ci;
        c.focusRow = r;
        WXFExposeSessionSetNeedsLayout(s);
        return;
    }
}

// A sideways swipe scrolls the strip with the fingers and settles on a column; a vertical one
// toggles the overview. Every event of a swipe we took is consumed so Spaces / Mission Control never
// see it. Returns true if the event is ours.
static bool Swipe(WXFExposeSessionRef s, WXFEventRef event) {
    WXFEventSwipeMotion motion;
    double progress;
    if (!WXFEventGetDockSwipe(event, &motion, &progress)) return false;
    WXFEventPhase phase = WXFEventGetPhase(event);

    if (!gSwipe.tracking) {
        if (!(phase & WXFEventPhaseBegan) || (motion != WXFEventSwipeMotionHorizontal && motion != WXFEventSwipeMotionVertical))
            return false;
        gSwipe.tracking = true;
        gSwipe.motion = motion;
        gNiri.drag = 0;
        os_log(OS_LOG_DEFAULT, "WXF niri: swipe began, motion %d progress %.3f", (int)motion, progress);
        return true;
    }

    if (gSwipe.motion == WXFEventSwipeMotionHorizontal) {
        double last = (double)gNiri.columns.count - 1;
        double want = -progress * kSwipeRightSign * kSwipeColumns;
        gNiri.drag = fmin(fmax(want, -(double)gNiri.focus), last - (double)gNiri.focus);
        WXFExposeSessionSetNeedsLayout(s);
    }
    if (phase & (WXFEventPhaseEnded | WXFEventPhaseCancelled)) {
        gSwipe.tracking = false;
        os_log(OS_LOG_DEFAULT, "WXF niri: swipe %s at progress %.3f", (phase & WXFEventPhaseEnded) ? "ended" : "cancelled", progress);
        if (gSwipe.motion == WXFEventSwipeMotionHorizontal) {
            long to = (long)gNiri.focus + (long)lround(gNiri.drag);
            gNiri.drag = 0;
            if (phase & WXFEventPhaseEnded) FocusColumn(s, to); else WXFExposeSessionSetNeedsLayout(s);
        } else if ((phase & WXFEventPhaseEnded) && fabs(progress) >= kSwipeCommit) {
            SetOverview(s, progress > 0);       // up (positive, as seen for Mission Control) zooms out
        }
    }
    return true;
}

static void Consume(uint16_t key) { if (key < 128) gKeyDown[key] = true; }

static bool HandleEvent(WXFExposeSessionRef session, WXFEventRef event, void *info) {
    (void)info;
    if (!gNiri.columns.count) return false;
    switch (WXFEventGetType(event)) {
        case WXFEventTypeDockSwipe:
            return Swipe(session, event);
        case WXFEventTypeKeyUp: {
            uint16_t key = WXFEventGetKeyCode(event);
            if (key < 128 && gKeyDown[key]) { gKeyDown[key] = false; return true; }
            return false;
        }
        case WXFEventTypeKeyDown: {
            uint32_t flags = WXFEventGetFlags(event);
            bool shift = flags & WXFEventFlagShift;
            uint32_t mods = flags & (WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand | WXFEventFlagFunction);
            if (mods != (WXFEventFlagControl | WXFEventFlagOption)) return false;   // not for us
            uint16_t key = WXFEventGetKeyCode(event);
            switch (key) {
                case kVKLeftArrow: case kVKH:
                    if (shift) MoveColumn(session, -1); else FocusColumn(session, (long)gNiri.focus - 1);
                    break;
                case kVKRightArrow: case kVKL:
                    if (shift) MoveColumn(session, 1); else FocusColumn(session, (long)gNiri.focus + 1);
                    break;
                case kVKUpArrow: case kVKK:
                    if (shift) MoveRow(session, -1); else FocusRow(session, (long)Focused().focusRow - 1);
                    break;
                case kVKDownArrow: case kVKJ:
                    if (shift) MoveRow(session, 1); else FocusRow(session, (long)Focused().focusRow + 1);
                    break;
                case kVKComma:  ConsumeLeft(session); break;
                case kVKPeriod: ExpelRight(session); break;
                case kVKR:      CycleWidth(session); break;
                case kVKTab:    SetOverview(session, !gNiri.overviewOn); break;
                default: return false;
            }
            Consume(key);
            return true;
        }
        case WXFEventTypeMouseDown: {
            WXFExposeItemRef hit = WXFExposeSessionHitTest(session, WXFEventGetLocation(event));
            if (!hit) return false;
            FocusWindow(session, @(WXFExposeItemGetWindowID(hit)));
            // The strip decides where windows are: a drag that starts in a title bar goes nowhere. The
            // click itself still reaches the window (its buttons work); dragging inside a window
            // (selecting, scrolling, sliders) is left alone.
            CGPoint corners[4], at = WXFEventGetLocation(event);
            double scale = WXFExposeItemGetLayout(hit).scale.height;
            gSuppressDrag = WXFExposeItemGetQuad(hit, corners) && scale > 0 &&
                            (at.y - corners[0].y) / scale < kTitleBar;
            if (gNiri.overviewOn) {         // pick from the overview: zoom in on it, the click is spent
                SetOverview(session, false);
                ActivateFocused(session);
                return true;
            }
            return false;                   // otherwise the click goes to the window
        }
        case WXFEventTypeMouseDragged:
            return gSuppressDrag;
        case WXFEventTypeMouseUp:
            gSuppressDrag = false;
            return false;
        default:
            return false;
    }
}

static void WillEnd(WXFExposeSessionRef session, WXFExposeEndReason reason, WXFExposeItemRef selected, void *info) {
    (void)session; (void)selected; (void)info;
    // Control+Option+Command+Escape (the framework's way out) is a request to stop, not to restart.
    if (reason == WXFExposeEndReasonCancelled) gNiri.enabled = false;
}

static void DidEnd(WXFExposeSessionRef session, void *info) {
    (void)session; (void)info;
    gNiri.columns = nil;
    gNiri.itemOf = nil;
    gSwipe.tracking = false;
    os_log(OS_LOG_DEFAULT, "WXF niri: off");
}

// MARK: Always on

// Brings the strip up when it should be and there are windows, and keeps its window set current.
static void Poll(void *info, double now) {
    (void)info; (void)now;
    WXFExposeSessionRef s = WXFExposeGetActiveSession();
    if (s) {
        if (!WXFExposeSessionIsEnding(s)) WXFExposeSessionReload(s);
    } else if (gNiri.enabled) {
        WXFExposeBegin(gProvider, WXFExposeScopeAllWindows);
    }
    WXFScheduleCallback(Poll, NULL, WXFCurrentTime() + kPoll);
}

// Control+Option+N turns the strip off and on. Claiming the key here, before WindowServer matches
// its hot keys, keeps the application from seeing it.
static bool gSwallowKeyUp;

static WXFEventDisposition Trigger(WXFEventRef event, void *info) {
    (void)info;
    uint16_t key = WXFEventGetKeyCode(event);
    if (key != kVKN) return WXFEventDispositionPass;
    if (WXFEventGetType(event) == WXFEventTypeKeyUp) {
        if (!gSwallowKeyUp) return WXFEventDispositionPass;
        gSwallowKeyUp = false;
        return WXFEventDispositionConsume;
    }
    uint32_t mods = WXFEventGetFlags(event) & (WXFEventFlagShift | WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand);
    if (mods != (WXFEventFlagControl | WXFEventFlagOption)) return WXFEventDispositionPass;

    gSwallowKeyUp = true;
    WXFExposeSessionRef s = WXFExposeGetActiveSession();
    if (s) {
        gNiri.enabled = false;
        WXFExposeEnd(s, WXFExposeEndReasonRequested, NULL);
    } else {
        gNiri.enabled = true;
        if (!WXFExposeBegin(gProvider, WXFExposeScopeAllWindows)) os_log(OS_LOG_DEFAULT, "WXF niri: could not begin");
    }
    return WXFEventDispositionConsume;
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);

    WXFExposeCallbacks callbacks = {
        .version = 1,
        .didBegin = DidBegin,
        .layout = Layout,
        .handleEvent = HandleEvent,
        .willEnd = WillEnd,
        .didEnd = DidEnd,
        .didReload = DidReload,
        .options = WXFExposeOptionPassInput,
    };
    gProvider = WXFExposeProviderCreate(&callbacks);
    gNiri.enabled = true;
    WXFEventHandlerID handler = WXFEventAddHandler(WXFEventTypeKeyDown | WXFEventTypeKeyUp, Trigger, NULL);
    WXFScheduleCallback(Poll, NULL, WXFCurrentTime() + 2.0);
    os_log(OS_LOG_DEFAULT, "WXF niri: loaded, provider %p, key handler %u", gProvider, handler);
}
