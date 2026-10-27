//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// A cover flow in place of Mission Control. Control+Up shows every window on the display under
// the cursor as a row of cards, Control+Down only the windows of the frontmost application. Left
// and right arrows (or the scroll wheel, or a click on a side card) move through them, Return or a
// click on the middle card picks it, Escape or the shortcut again puts everything back. Control +
// Option + Command + Escape always gets out.
//
// The framework's part is the window list, the 3D transforms and the frame clock. This file is the
// layout (Layout) and the input (HandleEvent); nothing else is Exposé-specific.

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/WXFEvent.h>
#include <WindowServerFramework/WXFExpose.h>
#include <math.h>
#include <os/log.h>

enum { kVKReturn = 36, kVKLeftArrow = 123, kVKRightArrow = 124, kVKDownArrow = 125, kVKUpArrow = 126 };

static const double kGap = 40.0;            // between neighbouring cards, in points
static const double kIntro = 0.35;          // seconds to fly in or out
static const double kStiffness = 90.0;      // the spring that carries the row from card to card
static const double kDamping = 2.0 * 9.5;   // about critical for that stiffness

static struct {
    double position;        // which card is in the middle, fractional while the row moves
    double velocity;
    double target;          // the card that will be
    double progress;        // 0 = windows where they were, 1 = cover flow
    double scroll;          // lines scrolled toward the next card, not yet used
    bool interactive;       // a trackpad swipe is setting `progress`
} gFlow;

// The Mission Control swipe: a swipe up gives a positive progress (seen in the log of a live test).
static const double kSwipeUpSign = 1.0;
static const double kSwipeCommit = 0.25;    // how far a swipe has to get to stay open / to close

static struct {
    bool tracking;          // this vertical swipe is ours
    bool closing;           // it began with the view up
    double start;           // gFlow.progress when it began
} gSwipe;

static WXFExposeProviderRef gProvider;

static float Smooth(double t) {
    t = fmin(fmax(t, 0), 1);
    return (float)(t * t * (3 - 2 * t));
}

static float Lerp(float a, float b, float t) { return a + (b - a) * t; }

// Where card `i` is along a row laid out end to end with a gap between the cards, measured from
// the row's start to the card's centre.
static double RowCenter(WXFExposeSessionRef session, long i) {
    double x = 0;
    for (long j = 0; j < i; j++)
        x += WXFExposeItemGetFrame(WXFExposeSessionGetItemAtIndex(session, j)).size.width + kGap;
    return x + WXFExposeItemGetFrame(WXFExposeSessionGetItemAtIndex(session, i)).size.width / 2;
}

// The layout for `item` with the row at `position`, on a display of size `bounds`.
static WXFExposeItemLayout CardLayout(WXFExposeSessionRef session, WXFExposeItemRef item, double position,
                                      CGRect bounds) {
    // Windows keep their own size and sit side by side with a gap, so none overlaps. The card at
    // `position` (between two cards while the row moves) is centred. `translationZ` only orders the
    // cards, nearest the middle in front; with no `perspective` it moves nothing.
    long count = WXFExposeSessionGetItemCount(session);
    double p = fmin(fmax(position, 0), (double)count - 1);
    long lo = (long)floor(p), hi = MIN(lo + 1, count - 1);
    double middle = RowCenter(session, lo) + (RowCenter(session, hi) - RowCenter(session, lo)) * (p - (double)lo);
    double a = fabs((double)WXFExposeItemGetIndex(item) - position);

    WXFExposeItemLayout l = {0};
    l.center = CGPointMake(CGRectGetMidX(bounds) + RowCenter(session, WXFExposeItemGetIndex(item)) - middle,
                           CGRectGetMidY(bounds));
    l.scale = CGSizeMake(1, 1);
    l.translationZ = (float)-a;
    l.alpha = (float)fmax(0.0, 1.0 - fmax(0.0, a - 2.5) * 0.5);
    return l;
}

static WXFExposeItemLayout Blend(WXFExposeItemLayout from, WXFExposeItemLayout to, float t) {
    WXFExposeItemLayout l;
    l.center = CGPointMake(Lerp(from.center.x, to.center.x, t), Lerp(from.center.y, to.center.y, t));
    l.scale = CGSizeMake(Lerp(from.scale.width, to.scale.width, t), Lerp(from.scale.height, to.scale.height, t));
    l.rotationX = Lerp(from.rotationX, to.rotationX, t);
    l.rotationY = Lerp(from.rotationY, to.rotationY, t);
    l.rotationZ = Lerp(from.rotationZ, to.rotationZ, t);
    l.translationZ = Lerp(from.translationZ, to.translationZ, t);
    l.perspective = to.perspective;
    l.eye = to.eye;
    l.alpha = Lerp(from.alpha, to.alpha, t);
    return l;
}

static void DidBegin(WXFExposeSessionRef session, void *info) {
    (void)info;
    gFlow.position = gFlow.target = 0;
    gFlow.velocity = 0;
    gFlow.progress = 0;
    gFlow.scroll = 0;
    gFlow.interactive = gSwipe.tracking;

    os_log(OS_LOG_DEFAULT, "WXF cover flow: %ld windows", WXFExposeSessionGetItemCount(session));
}

static bool Layout(WXFExposeSessionRef session, const WXFExposeFrame *frame, void *info) {
    (void)info;
    double dt = fmin(frame->delta, 1.0 / 30.0);

    // The row: a damped spring toward the target card.
    double accel = kStiffness * (gFlow.target - gFlow.position) - kDamping * gFlow.velocity;
    gFlow.velocity += accel * dt;
    gFlow.position += gFlow.velocity * dt;
    bool rowMoving = fabs(gFlow.target - gFlow.position) > 0.0005 || fabs(gFlow.velocity) > 0.001;
    if (!rowMoving) {
        gFlow.position = gFlow.target;
        gFlow.velocity = 0;
    }

    // The fly-in and fly-out, or wherever the fingers are.
    if (!gFlow.interactive || frame->ending)
        gFlow.progress += (frame->ending ? -dt : dt) / kIntro;
    gFlow.progress = fmin(fmax(gFlow.progress, 0), 1);
    float t = Smooth(gFlow.progress);

    // Windows that were left out (other applications' in the front-application scope) fade away
    // with the cards coming in. The desktop, menu bar and Dock stay; that is up to the tweak too.
    for (long i = 0, n = WXFExposeSessionGetBackgroundCount(session); i < n; i++) {
        WXFExposeBackgroundRef bg = WXFExposeSessionGetBackgroundAtIndex(session, i);
        if (WXFExposeBackgroundGetKind(bg) == WXFExposeBackgroundKindWindow)
            WXFExposeBackgroundSetAlpha(bg, 1.0f - t);
    }

    long count = WXFExposeSessionGetItemCount(session);
    for (long i = 0; i < count; i++) {
        WXFExposeItemRef item = WXFExposeSessionGetItemAtIndex(session, i);
        WXFExposeItemLayout natural = {0};
        CGRect f = WXFExposeItemGetFrame(item);
        natural.center = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        natural.scale = CGSizeMake(1, 1);
        natural.alpha = 1;
        WXFExposeItemLayout target = CardLayout(session, item, gFlow.position, frame->bounds);
        WXFExposeItemLayout blended = Blend(natural, target, t);
        WXFExposeItemSetLayout(item, &blended);
    }

    if (frame->ending) return gFlow.progress > 0;
    return rowMoving || gFlow.progress < 1;
}

static void Move(WXFExposeSessionRef session, double to) {
    double last = (double)WXFExposeSessionGetItemCount(session) - 1;
    gFlow.target = fmin(fmax(round(to), 0), last);
    WXFExposeSessionSetNeedsLayout(session);
}

// A vertical dock swipe: up opens all windows, down the front application's (as the Dock does),
// following the fingers; one while the view is up closes it. Returns true if it is ours.
static bool Swipe(WXFEventRef event) {
    WXFEventSwipeMotion motion;
    double progress;
    if (!WXFEventGetDockSwipe(event, &motion, &progress)) return false;
    WXFEventPhase phase = WXFEventGetPhase(event);
    WXFExposeSessionRef session = WXFExposeGetActiveSession();

    if (!gSwipe.tracking) {
        if (motion != WXFEventSwipeMotionVertical || !(phase & WXFEventPhaseBegan)) return false;
        gSwipe.tracking = true;
        gSwipe.closing = session != NULL;
        gSwipe.start = session ? gFlow.progress : 0;
        os_log(OS_LOG_DEFAULT, "WXF cover flow: swipe began, progress %.3f, view %s", progress, session ? "up" : "down");
        return true;
    }

    double up = progress * kSwipeUpSign;        // positive when the fingers went up
    if (!session && !gSwipe.closing && fabs(progress) > 0.01) {
        WXFExposeScope scope = up > 0 ? WXFExposeScopeAllWindows : WXFExposeScopeFrontApplication;
        session = WXFExposeBegin(gProvider, scope);
        os_log(OS_LOG_DEFAULT, "WXF cover flow: swipe progress %.3f, opening scope %d%s", progress, (int)scope,
               session ? "" : " failed");
        gSwipe.start = 0;
    }
    if (session && !WXFExposeSessionIsEnding(session)) {
        // Opening follows the distance either way; closing, only a swipe toward closing.
        double p = gSwipe.closing ? gSwipe.start - fabs(up) : fabs(up);
        gFlow.progress = fmin(fmax(p, 0), 1);
        gFlow.interactive = true;
        WXFExposeSessionSetNeedsLayout(session);
    }

    if (phase & (WXFEventPhaseEnded | WXFEventPhaseCancelled)) {
        gSwipe.tracking = false;
        gFlow.interactive = false;
        os_log(OS_LOG_DEFAULT, "WXF cover flow: swipe %s at progress %.3f", (phase & WXFEventPhaseEnded) ? "ended" : "cancelled", progress);
        if (session && !WXFExposeSessionIsEnding(session)) {
            bool keep = (phase & WXFEventPhaseEnded) &&
                        (gSwipe.closing ? gFlow.progress > 1 - kSwipeCommit : gFlow.progress >= kSwipeCommit);
            if (keep) WXFExposeSessionSetNeedsLayout(session);      // settles open
            else WXFExposeEnd(session, WXFExposeEndReasonCancelled, NULL);
        }
    }
    return true;
}

static bool HandleEvent(WXFExposeSessionRef session, WXFEventRef event, void *info) {
    (void)info;
    switch (WXFEventGetType(event)) {
        case WXFEventTypeDockSwipe:
            Swipe(event);
            return true;        // a swipe while the view is up never reaches the Dock
        case WXFEventTypeKeyDown:
            switch (WXFEventGetKeyCode(event)) {
                case kVKLeftArrow:  Move(session, gFlow.target - 1); return true;
                case kVKRightArrow: Move(session, gFlow.target + 1); return true;
                case kVKReturn:
                    WXFExposeEnd(session, WXFExposeEndReasonSelected,
                                 WXFExposeSessionGetItemAtIndex(session, (long)gFlow.target));
                    return true;
                case kVKUpArrow:
                    if (WXFEventGetFlags(event) & WXFEventFlagControl) {      // the shortcut again
                        WXFExposeEnd(session, WXFExposeEndReasonCancelled, NULL);
                        return true;
                    }
                    return false;
                default: return false;
            }
        case WXFEventTypeScrollWheel: {
            // One card per line, so a wheel click moves one card and a trackpad's small
            // deltas add up to one.
            CGPoint delta = WXFEventGetScrollDelta(event);
            gFlow.scroll += fabs(delta.x) > fabs(delta.y) ? delta.x : -delta.y;
            if (fabs(gFlow.scroll) >= 1) {
                double step = trunc(gFlow.scroll);
                gFlow.scroll -= step;
                Move(session, gFlow.target + step);
            }
            return true;
        }
        case WXFEventTypeMouseDown: {
            WXFExposeItemRef hit = WXFExposeSessionHitTest(session, WXFEventGetLocation(event));
            if (!hit || WXFExposeItemGetIndex(hit) == (long)gFlow.target)
                return false;           // the middle card, or nothing: the default picks or cancels
            Move(session, (double)WXFExposeItemGetIndex(hit));
            return true;
        }
        default:
            return false;
    }
}

static void DidEnd(WXFExposeSessionRef session, void *info) {
    (void)session; (void)info;
    os_log(OS_LOG_DEFAULT, "WXF cover flow: done");
}

// Control+Up / Control+Down start the view. Claiming the key here, before WindowServer matches its
// hot keys, is what keeps the Dock's own Mission Control from also opening.
static bool gSwallowKeyUp;
static uint16_t gSwallowedKey;

static WXFEventDisposition Trigger(WXFEventRef event, void *info) {
    (void)info;
    if (WXFEventGetType(event) == WXFEventTypeDockSwipe)
        return Swipe(event) ? WXFEventDispositionConsume : WXFEventDispositionPass;
    uint16_t key = WXFEventGetKeyCode(event);
    if (WXFEventGetType(event) == WXFEventTypeKeyUp) {
        if (gSwallowKeyUp && key == gSwallowedKey) {
            gSwallowKeyUp = false;
            return WXFEventDispositionConsume;
        }
        return WXFEventDispositionPass;
    }
    if (key != kVKUpArrow && key != kVKDownArrow) return WXFEventDispositionPass;
    uint32_t mods = WXFEventGetFlags(event) &
                    (WXFEventFlagShift | WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand);
    if (mods != WXFEventFlagControl) return WXFEventDispositionPass;

    WXFExposeScope scope = key == kVKUpArrow ? WXFExposeScopeAllWindows : WXFExposeScopeFrontApplication;
    if (!WXFExposeBegin(gProvider, scope)) {
        os_log(OS_LOG_DEFAULT, "WXF cover flow: could not begin");
        return WXFEventDispositionPass;
    }
    gSwallowKeyUp = true;
    gSwallowedKey = key;
    return WXFEventDispositionConsume;
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);

    WXFExposeCallbacks callbacks = {
        .didBegin = DidBegin,
        .layout = Layout,
        .handleEvent = HandleEvent,
        .didEnd = DidEnd,
    };
    gProvider = WXFExposeProviderCreate(&callbacks);
    WXFEventHandlerID handler = WXFEventAddHandler(WXFEventTypeKeyDown | WXFEventTypeKeyUp | WXFEventTypeDockSwipe,
                                                    Trigger, NULL);
    os_log(OS_LOG_DEFAULT, "WXF cover flow: loaded, provider %p, key handler %u", gProvider, handler);
}
