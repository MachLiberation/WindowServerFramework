//
//  WXFEvent.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Server-side input: look at every keyboard, mouse, scroll and gesture event as WindowServer
// processes it, and consume the ones your tweak handles so no application sees them. This is what
// a custom Exposé view uses to drive itself, and it works on its own for any other shortcut or
// modal interaction.

#ifndef WXFEVENT_H
#define WXFEVENT_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>
#include <WindowServerFramework/WXFBase.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __WXFEvent;
/// Describes one input event. Only valid for the duration of the callback; do not retain it.
typedef struct __WXFEvent *WXFEventRef;

typedef enum {
    WXFEventTypeKeyDown        = 1 << 0,
    WXFEventTypeKeyUp          = 1 << 1,
    /// A modifier key changed (shift, control, option, command, fn).
    WXFEventTypeFlagsChanged   = 1 << 2,
    WXFEventTypeMouseDown      = 1 << 3,
    WXFEventTypeMouseUp        = 1 << 4,
    WXFEventTypeMouseMoved     = 1 << 5,
    WXFEventTypeMouseDragged   = 1 << 6,
    WXFEventTypeScrollWheel    = 1 << 7,
    /// Trackpad gestures (swipe, magnify, rotate and the like).
    WXFEventTypeGesture        = 1 << 8,
    /// A symbolic hot key fired, such as Mission Control. `WXFEventGetSymbolicHotKey` says which.
    WXFEventTypeSymbolicHotKey = 1 << 9,
    /// The trackpad's system swipes (Mission Control, App Exposé, Spaces) on their way to the Dock.
    /// Consuming every event of a swipe keeps the Dock from acting on it. See WXFEventGetDockSwipe.
    WXFEventTypeDockSwipe      = 1 << 10,
    WXFEventTypeKey            = WXFEventTypeKeyDown | WXFEventTypeKeyUp | WXFEventTypeFlagsChanged,
    WXFEventTypeMouse          = WXFEventTypeMouseDown | WXFEventTypeMouseUp | WXFEventTypeMouseMoved |
                                 WXFEventTypeMouseDragged,
    WXFEventTypeAll            = 0x7ff,
} WXFEventType;

/// Where a gesture is in its life (IOHIDEventPhaseBits).
typedef enum {
    WXFEventPhaseNone      = 0,
    WXFEventPhaseBegan     = 1 << 0,
    WXFEventPhaseChanged   = 1 << 1,
    WXFEventPhaseEnded     = 1 << 2,
    WXFEventPhaseCancelled = 1 << 3,
    WXFEventPhaseMayBegin  = 1 << 7,
} WXFEventPhase;

/// What a dock swipe is doing (IOHIDGestureMotion).
typedef enum {
    WXFEventSwipeMotionNone       = 0,
    /// Left or right: switching Spaces.
    WXFEventSwipeMotionHorizontal = 1,
    /// Up or down: Mission Control and App Exposé.
    WXFEventSwipeMotionVertical   = 2,
    /// Pinch or spread: Launchpad and Show Desktop.
    WXFEventSwipeMotionScale      = 3,
} WXFEventSwipeMotion;

typedef enum {
    /// Let the event continue to the next handler and then to applications.
    WXFEventDispositionPass    = 0,
    /// Stop here: no later handler and no application sees this event.
    WXFEventDispositionConsume = 1,
} WXFEventDisposition;

/// Modifier flags, with the same bits as CGEventFlags.
enum {
    WXFEventFlagShift    = 0x00020000,
    WXFEventFlagControl  = 0x00040000,
    WXFEventFlagOption   = 0x00080000,
    WXFEventFlagCommand  = 0x00100000,
    WXFEventFlagFunction = 0x00800000,
    /// The modifiers above, which is what shortcuts compare.
    WXFEventFlagMask     = 0x009e0000,
};

/// Called on WindowServer's event thread for each event in the handler's mask. Keep it fast.
/// The newest handler is called first; the first to return Consume ends the chain.
typedef WXFEventDisposition (*WXFEventCallback)(WXFEventRef event, void *userInfo);

typedef uint32_t WXFEventHandlerID;
#define WXFEventHandlerIDInvalid ((WXFEventHandlerID)0)

/// Registers a handler for the event types in `typeMask`. Installs the WindowServer hooks the
/// first time it is called (requires SetupFramework to have been called).
/// @return a handler id, or WXFEventHandlerIDInvalid on failure.
WXFEventHandlerID WXFEventAddHandler(uint32_t typeMask, WXFEventCallback callback, void *userInfo);

/// Removes a handler. @return true if it existed.
bool WXFEventRemoveHandler(WXFEventHandlerID handler);

/// The kind of event, one of the WXFEventType bits.
WXFEventType WXFEventGetType(WXFEventRef event);

/// The cursor position in screen coordinates (top-left origin) when the event happened. Valid for
/// every type except the key ones, where it is the position of the last pointer event.
CGPoint WXFEventGetLocation(WXFEventRef event);

/// Modifier flags in force for this event (WXFEventFlag*).
uint32_t WXFEventGetFlags(WXFEventRef event);

/// Virtual key code (kVK_*) for key down / up events; 0 otherwise.
uint16_t WXFEventGetKeyCode(WXFEventRef event);

/// 0 for the left button, 1 for the right button, 2 and up for the others. Mouse button and drag
/// events only; 0 otherwise.
uint32_t WXFEventGetButton(WXFEventRef event);

/// Scroll amount in lines (fractional for trackpads) for scroll wheel events, zero otherwise: x is
/// axis 2 (horizontal), y is axis 1 (vertical), with the signs of CGEvent's
/// scrollWheelEventDeltaAxis*. A trackpad sends many small deltas, so accumulate them.
CGPoint WXFEventGetScrollDelta(WXFEventRef event);

/// For a WXFEventTypeSymbolicHotKey event, which hot key it is (see WXFSymbolicHotKey below);
/// 0 otherwise. `pressed` is false for the release.
/// The phase of a gesture or dock swipe event; WXFEventPhaseNone for other types.
WXFEventPhase WXFEventGetPhase(WXFEventRef event);

/// For a dock swipe: its motion and progress (signed: one sign for each direction; about 1 for a
/// full swipe). @return false for other events.
bool WXFEventGetDockSwipe(WXFEventRef event, WXFEventSwipeMotion *motion, double *progress);

uint32_t WXFEventGetSymbolicHotKey(WXFEventRef event, bool *pressed);

/// The event type as WindowServer numbers it (CGEventType-like). For anything the other accessors
/// don't cover.
uint32_t WXFEventGetRawType(WXFEventRef event);

/// Well-known symbolic hot key ids (the standard system table, not checked in this build).
enum {
    WXFSymbolicHotKeyMissionControl     = 32,
    WXFSymbolicHotKeyApplicationWindows = 33,
    WXFSymbolicHotKeyShowDesktop        = 36,
};

#ifdef __cplusplus
}
#endif

#endif /* WXFEVENT_H */
