# WindowServerFramework API

WindowServerFramework is a shared library that Ammonia tweaks use to customize WindowServer
without reverse engineering it themselves. The API is plain C, prefixed `WXF`. The internals it
relies on are written up in [drag-internals.md](drag-internals.md).

## Setup

The framework is one dynamic library, installed at
`/private/var/ammonia/core/tweaks/WindowServerFramework.framework`. Tweaks link against it, and
dyld loads that single copy for all of them, so it hooks WindowServer once no matter how many
tweaks use it. Where two tweaks want the same thing (for instance two drag shaders), the later
one wins for that drag.

Call `SetupFramework` first, from your tweak's `LoadFunction`, with the Gum interceptor Ammonia
passes in:

```c
#include <WindowServerFramework/WindowServerFramework.h>

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    // ...
}
```

`scripts/deploy.sh [Target...]` builds, signs and installs tweak targets and the framework.
Ammonia only loads tweaks when WindowServer starts, so restart it afterwards
(`sudo killall WindowServer`; this logs you out).

## Drag shaders

Draw a dragged window through your own Metal fragment shader: jello, trails, ripples, anything
that can be done from a snapshot of the window. The framework supplies the stand-in window, the
geometry and the timing. The effect lives entirely in your tweak.

### How it works

When a drag with a shader begins, the framework takes a snapshot of the window, covers it with an
overlay window that is the window's frame plus a margin, and hides the real window. Your shader
draws the overlay each frame, sampling the snapshot. The overlay follows the window. When the
drag ends, the overlay stays up until your effect has settled, then the real window comes back.
The snapshot is static, so the window's contents don't update during the drag.

### One-call setup

```c
static bool JelloParams(const WXFDragFrame *f, float out[WXF_DRAG_SHADER_DATA_COUNT], void *info) {
    // fill out[] for this frame; return true while the effect is still moving
}

void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    static const WXFDragShaderDescriptor jello = {
        .fragment = "wxf_example_jello",
        .params   = JelloParams,
        .margin   = 170,
    };
    WXFDragInstallShader(&jello);
}
```

`WXFDragInstallShader` makes every window drag use the shader, with the metallib embedded in the
calling dylib. It returns an observer id for `WXFDragRemoveObserver`.

| Descriptor field | Meaning |
| --- | --- |
| `fragment` | Name of the fragment function in your metallib. Required. |
| `params` | `WXFDragShaderParamFunction`, called every frame. Optional. |
| `userInfo` | Passed back to `params`. |
| `margin` | Points the shader may draw past the window on every side. Default 0. Large margins cost fill rate. |
| `durationNanoseconds` | Minimum time the overlay lingers after release. 0 means 150 ms. |
| `easing` | Curve for the framework's `progress` value. |

For more control, such as shading only some drags, build the animation yourself and attach it
from a drag observer (see below).

### Writing the shader

Write a `.metal` file that includes `sdk/WXFDragShader.metal`, and compile it to a metallib at
build time. WindowServer only loads finished libraries; it never compiles source. Embed the
metallib in your dylib so installing the dylib alone is enough:

```
-sectcreate __DATA __wxf_shader <path to .metallib>
```

(`DragShaderExample` does this with a "Compile drag shader" build phase and `OTHER_LDFLAGS`.)

```metal
#include "../sdk/WXFDragShader.metal"

fragment float4 my_effect(WXFDragStage in [[stage_in]],
                          texture2d<float> tex2D [[texture(0)]],
                          constant WXFDragArgs &args [[buffer(0)]],
                          constant WXFDragExtra &extra [[buffer(WXF_EXTRA_INDEX)]],
                          sampler samp [[sampler(0)]]) {
    float2 uv = wxf_window_uv(in);
    return tex2D.sample(samp, uv);   // premultiplied
}
```

The signature mirrors SkyLight's own `UberCompositeFragment`; keep the argument list exactly as
shown. Return a premultiplied color. The helpers:

| Helper | Returns |
| --- | --- |
| `wxf_window_uv(in)` | This fragment's 0..1 coordinate over the whole overlay. Sample the snapshot with it. |
| `wxf_frame_size(extra)` | The overlay's size in points. |
| `wxf_point(in, extra)` | This fragment's position in points, top-left origin. |
| `wxf_window_frame(extra)` | The window's frame (content plus shadow) inside the overlay: `(min.x, min.y, max.x, max.y)`. |
| `wxf_window_content(extra)` | The window's own pixels (no shadow), same layout. |
| `wxf_in_frame(p, extra)`, `wxf_in_window(p, extra)` | Whether a point is inside the frame or the content. |
| `wxf_progress(extra)` | The drag's eased progress: 0 at rest, about 1 while held, back to 0 after release. |
| `wxf_param(extra, i)` | The i-th float your params function wrote (0 to `WXF_DATA_COUNT - 1`). |

`extra.bound` is 0 when the fragment is drawing a window that isn't the dragged one; return the
plain texture then.

### The params function

```c
typedef bool (*WXFDragShaderParamFunction)(const WXFDragFrame *frame,
                                           float out[WXF_DRAG_SHADER_DATA_COUNT], void *userInfo);
```

Called on WindowServer's main thread about every 1/60 s while the animation is live. Fill `out`
(40 floats, zeroed first) and return true while your effect is still moving. After the release,
the overlay stays up as long as you keep returning true (and for at least the animation's
duration, at most 10 seconds), so a spring can settle instead of being cut off. Return false when
you are done, ideally when the effect is at rest, so the hand back to the real window is
invisible.

`WXFDragFrame`:

| Field | Meaning |
| --- | --- |
| `window` | The dragged window. |
| `frame` | The window's frame in screen coordinates. |
| `cursor`, `cursorValid` | The cursor in screen coordinates, when it could be read. |
| `velocity` | Window velocity in points per second, smoothed. |
| `progress` | Eased 0..1 amount (the spring curve can overshoot). |
| `elapsed` | Seconds since the drag began. |
| `releasing` | True once the window has been released. |
| `intensity` | The animation's intensity setting, percent, for your own use. |

### Building the animation yourself

`WXFDragAnimation` is the object `WXFDragInstallShader` builds for each drag.

| Function | What it does |
| --- | --- |
| `WXFDragAnimationCreate()` | New animation, +1 retained. Defaults: 150 ms, ease in/out, no delay, intensity 100, no shader. |
| `WXFDragAnimationSetShader(anim, metallib, length, fragment, params, userInfo)` | Uses a metallib you loaded. The bytes are copied. |
| `WXFDragAnimationSetShaderFile(anim, path, fragment, params, userInfo)` | As above, reading a file. |
| `WXFDragAnimationSetEmbeddedShader(anim, fragment, params, userInfo)` | Uses the metallib embedded in the calling image. |
| `WXFDragAnimationGetShader(...)` | Reads the configuration back. |
| `WXFDragAnimationSetMargin` / `GetMargin` | Points the shader may draw past the window (0 to 2000). |
| `WXFDragAnimationSetDuration` / `GetDuration` | Nanoseconds for `progress` to go 0 to 1, and back after release. |
| `WXFDragAnimationSetEasing` / `GetEasing` | `EaseInEaseOut`, `Spring` or `Linear`. |
| `WXFDragAnimationSetDelay` / `GetDelay` | Nanoseconds before progress starts rising. |
| `WXFDragAnimationSetIntensity` / `GetIntensity` | Percent, passed to your params function. |
| `WXFDragAnimationEvaluateEasing(anim, t)` | Applies the easing curve to a linear 0..1 value. |

Release an animation with `WXFRelease` when you are done with it. The drag retains the one you
attach.

## Drag events

`WXFDragAddObserver(mask, callback, userInfo)` calls you on WindowServer's thread for each drag
event in `mask`; keep it fast. `WXFDragRemoveObserver` removes it. The context is only valid
inside the callback.

| Phase | When |
| --- | --- |
| `WXFDragPhaseBegin` | The user began dragging a window. |
| `WXFDragPhasePropose` | A new position is proposed, before it is committed. |
| `WXFDragPhaseMove` | A movement was committed. |
| `WXFDragPhaseWillEnd` | The drag is about to end. |
| `WXFDragPhaseDidEnd` | The drag ended. |
| `WXFDragPhaseAnimationBegin` | WindowServer applied a drag transform animation. |
| `WXFDragPhaseAnimationEnd` | WindowServer removed it. |
| `WXFDragPhaseAll` | All of the above. |

Inside a callback:

| Function | Returns |
| --- | --- |
| `WXFDragContextGetPhase` | The phase that triggered the callback. |
| `WXFDragContextGetWindow` | The dragged `CGXWindow *`, or NULL for phases reported without one. |
| `WXFDragContextIsTransformed` | Whether this is a transformed-window drag. |
| `WXFDragContextGetAnimation` | The animation attached to this drag, or NULL. |
| `WXFDragContextSetAnimation(context, anim)` | Attaches an animation to the drag in progress and starts it. NULL stops it at once and restores normal drawing. Call it from Begin or later. |

Tiled-space drags are not hooked yet.

## Events

`WXFEvent.h` lets a tweak see, and swallow, the input WindowServer is about to route. It is how
you catch the shortcut that starts a custom view, and how the view keeps clicks and keys away from
applications while it is up.

```c
static WXFEventDisposition OnEvent(WXFEventRef e, void *info) {
    if (WXFEventGetType(e) == WXFEventTypeKeyDown && WXFEventGetKeyCode(e) == 126 /* up */ &&
        (WXFEventGetFlags(e) & WXFEventFlagMask) == WXFEventFlagControl)
        return WXFEventDispositionConsume;      // nothing downstream sees it, the Dock included
    return WXFEventDispositionPass;
}
WXFEventAddHandler(WXFEventTypeKeyDown | WXFEventTypeKeyUp, OnEvent, NULL);
```

Handlers run on WindowServer's event thread, newest first; the first to return
`WXFEventDispositionConsume` ends the chain and the event goes no further. Keep them quick. The
event reference is only valid inside the callback. `WXFEventRemoveHandler(id)` removes one.

| Type | Events |
| --- | --- |
| `WXFEventTypeKeyDown` / `KeyUp` / `FlagsChanged` | Keys and modifier changes. |
| `WXFEventTypeMouseDown` / `MouseUp` | Any button. A consumed mouse-down never focuses or raises. |
| `WXFEventTypeMouseMoved` / `MouseDragged` | Pointer motion. |
| `WXFEventTypeScrollWheel` | Scrolling. |
| `WXFEventTypeGesture` | Trackpad gestures, as far as they pass through the event stages. |
| `WXFEventTypeSymbolicHotKey` | System shortcuts (Mission Control, Spaces, ...) before they are acted on. |
| `WXFEventTypeDockSwipe` | The trackpad's system swipes (Mission Control, App Exposé, Spaces) on their way to the Dock. Consume every event of a swipe to keep the Dock from acting on it. |

Accessors: `WXFEventGetType`, `GetLocation`, `GetFlags`, `GetKeyCode`, `GetButton`,
`GetScrollDelta` (lines, fractional for trackpads), `GetPhase` (gestures and swipes),
`GetDockSwipe` (motion and signed progress), `GetSymbolicHotKey`, `GetRawType`. Consuming the key-down of a shortcut gives the
matching key-up no owner, so swallow that too (the example tweak does).

The hooks install the first time a handler is added, in two groups, so a missing symbol on a
future OS only loses the events it carries. How the stages work, and what is verified, is in
[Expose internals](expose-internals.md).

## Custom Exposé

`WXFExpose.h` shows a view of the user's windows that **your tweak lays out**. The Dock is not
involved: you catch the shortcut (see Events), call `WXFExposeBegin`, and the framework moves the
real windows with the same per-window 3D transforms the Dock uses, so any arrangement works: a
grid, a cover flow, a carousel, a stack.

```c
WXFExposeCallbacks cb = { .layout = Layout, .handleEvent = HandleEvent };
WXFExposeProviderRef provider = WXFExposeProviderCreate(&cb);
WXFExposeSessionRef session = WXFExposeBegin(provider, WXFExposeScopeAllWindows);
```

A provider is a set of optional callbacks, shaped like `CFRunLoopSourceContext` (`info`, `retain`,
`release`). Everything is called on WindowServer's threads, so keep it quick.

| Callback | Purpose |
| --- | --- |
| `includeWindow` | Which windows take part. Default: ordinary windows (level 0). |
| `didBegin` | The view is up; items hold their natural layout. |
| `layout` | Every frame while animating, and after `WXFExposeSessionSetNeedsLayout`. Set each item's layout. Return `true` to be called again next frame, `false` when at rest. |
| `handleEvent` | Input while the view is up. Return `true` if you used it. |
| `willEnd` / `didEnd` | The view is going away / the windows are back. |

**Layout.** `WXFExposeItemLayout` says where a window's middle appears (`center`), how big
(`scale`), how it is turned (`rotationX/Y/Z`, radians), how far it is toward the viewer
(`translationZ`), and the camera (`perspective` distance in points, 0 for none, and the
vanishing point `eye`), plus `alpha`. All are relative to the window's natural place. The
framework builds the matrix, inverts it into the form WindowServer stores, and rejects nothing:
a scale of 0 is clamped. `WXFExposeItemGetQuad` gives the on-screen corners, and
`WXFExposeSessionHitTest` the frontmost window at a point.

**The windows behind.** Every window that doesn't take part (other applications' windows in the
front-application scope, anything `includeWindow` refused, the desktop picture and icons, the menu
bar, the Dock) is a `WXFExposeBackgroundRef`. `WXFExposeBackgroundSetAlpha(background, alpha)` fades
or hides it, from the same callbacks as the layouts, and the framework puts the alphas back when the
view ends. The framework applies no policy of its own. The example fades out the left-out ordinary
windows (so the front-application scope shows only that application) and leaves the desktop, menu
bar and Dock.

**Stacking.** WindowServer draws windows in stacking order, not by their transformed z. While the
view is up the framework therefore stacks them by `translationZ`, nearest the viewer in front, with
ties in their real order. The real order is put back when the view ends.

**Input.** The framework registers one event handler while a view is up. It runs yours first, then
does the defaults: Escape or a click outside every window cancels, a click on a window selects it,
other events are swallowed (modifier changes excepted). Control+option+command+escape always
cancels, as an escape hatch for a buggy provider. `WXFExposeEnd(session, reason, selected)` ends
the view yourself; once the windows are back the selected window's application is made the front
application and the window is ordered to the front.

**Lifetime.** One view at a time; a second `Begin` returns `NULL`. Item and window references are
valid until `didEnd` returns. If the tweak is unloaded or WindowServer exits there is nothing to
restore, since the transforms live in WindowServer.

**Example.** `ExposeExample` is a cover flow. ⌃↑ or a trackpad swipe up shows all windows, and ⌃↓
or a swipe down only the front application's. The fly-in follows the fingers, and a vertical swipe
while the view is up closes it. Arrows, scrolling and clicks move through the row, Return or a
click on the middle card selects it, and Escape cancels.

**Limitations.** There is no backdrop, no labels, no Spaces strip, and minimized windows are not
shown. The Dock's shortcuts and swipes still reach the Dock unless you
consume them as events.

**Testing.** `scripts/deploy.sh ExposeExample` builds and installs the tweak; WindowServer loads
tweaks only when it starts, so restart it (`sudo killall WindowServer`, which logs you out).
`scripts/deploy.sh --logs` streams the `WXF` log lines. The layout maths (forward/inverse
matrices, perspective, hit testing) is checked outside WindowServer.

## Menu bar

```c
#include <WindowServerFramework/WXFMenuBar.h>

WXFMenuBarSetThickness(36.0);   // points; 0 keeps the system's height
```

One hook on the function that returns the bar's rectangle sets the bar window, the part of the
screen windows can't be dragged into, the status items and the rectangle clients are told about
together. The setting is global; the later call wins. A call rebuilds the bar, so a change shows at
once. `MenuBarExample` makes the bar 36 points tall and binds Control + Option + Command + `[` / `]`
(thickness) and `\` (system height). Moving the bar to another edge is not offered; what that needs is
written up in [menubar-internals.md](menubar-internals.md).

## Misc

Declared in `WXFMisc.h`. The mid-level pieces the features are built from, for tweaks that need
something the features don't offer. Each call wraps one WindowServer function and does nothing
(returns 0, NULL or false) if that function is missing on this OS build; `WXFMiscIsAvailable(features)`
says up front whether a group of calls will work. Call them on WindowServer's main thread. A window
has one transform and one alpha, so a tweak that sets them on a window while Exposé or a drag
shader is using it will fight with it.

| Group | Functions |
| --- | --- |
| Availability | `WXFMiscIsAvailable(WXFMiscFeature...)` |
| Matrices | `WXFMat4` with `WXFMat4Identity`, `Multiply`, `MakeTranslation`, `MakeScale`, `MakeRotationX/Y/Z`, `Invert`, `ProjectPoint`, `FlattenToPlane`; `WXFQuadContainsPoint` |
| Clock | `WXFCurrentTime()`, `WXFScheduleCallback(fn, info, when)` (runs once, on the main thread) |
| Cursor and displays | `WXFGetCursorLocation`, `WXFDisplayForPoint`, `WXFDisplayGetMain`, `WXFDisplayGetBounds`, `WXFWindowGetDisplay` |
| Windows | `WXFWindowFromID`, `WXFWindowGetFrame` (ignores transforms), `WXFWindowGetClippedFrame` (with shadow), `WXFWindowGetScreenRect` (no shadow), `WXFWindowGetOwnerConnectionID`, `WXFCopyWindowList` |
| Alpha | `WXFWindowGetAlphaFactor`, `WXFWindowSetAlpha`, `WXFWindowUpdate` |
| Transforms | `WXFWindowApplyTransform(window, forward)` (give it the matrix that moves the window; it stores the inverse WindowServer wants), `WXFWindowResetTransform`, `WXFWindowSetTransform` (the stored matrix as is) |
| Moving and ordering | `WXFWindowMoveBy`, `WXFOrderWindow`, `WXFOrderWindowList`, `WXFRebuildVisibleOrder`, `WXFLogVisibleOrderMode` |
| Applications | `WXFForegroundConnection`, `WXFActivateWindowOwner` |

```c
// Tilt a window and fade it, then put it back.
CGXWindow *w = WXFWindowFromID(windowID);
CGRect f = WXFWindowGetFrame(w);
WXFMat4 m = WXFMat4MakeTranslation(-CGRectGetMidX(f), -CGRectGetMidY(f), 0);
m = WXFMat4Multiply(m, WXFMat4MakeRotationZ(0.2));
m = WXFMat4Multiply(m, WXFMat4MakeTranslation(CGRectGetMidX(f), CGRectGetMidY(f), 0));
WXFWindowApplyTransform(w, m);
WXFWindowSetAlpha(w, 0.5f);
// ...
WXFWindowResetTransform(w);
WXFWindowSetAlpha(w, 1.0f);
```

## Base

Declared in `WXFBase.h`.

| Function | What it does |
| --- | --- |
| `WXFRetain` / `WXFRelease` / `WXFGetTypeID` | Reference counting for framework objects such as animations. |
| `WXFIsFrameworkSetUp()` | Whether `SetupFramework` has run. |
| `WXFResolveServerSymbol(name)` | Looks up a WindowServer (SkyLight) symbol by raw Mach-O name, leading underscore included. NULL if absent on this OS build. |
| `HookServer(name, replacement, &original)` | Hooks a WindowServer symbol through Gum. The framework's own hooks are all installed from one table in `WXFHooks.c`; tweaks rarely need this. |
| `WXFResolveServerData(name)` | Like `WXFResolveServerSymbol` for a global variable: the variable's address, not a signed function pointer. |

## Adding framework features

Each feature gets its own example tweak target, named `<Feature>Example`. Hooks go in the table
in `api/WXFHooks.c`, never installed from feature files. See `AGENTS.md` for the rules and for
how to ground new hooks in IDA.
