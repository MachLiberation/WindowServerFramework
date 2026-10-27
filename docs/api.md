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

## Base

Declared in `WXFBase.h`.

| Function | What it does |
| --- | --- |
| `WXFRetain` / `WXFRelease` / `WXFGetTypeID` | Reference counting for framework objects such as animations. |
| `WXFIsFrameworkSetUp()` | Whether `SetupFramework` has run. |
| `WXFResolveServerSymbol(name)` | Looks up a WindowServer (SkyLight) symbol by raw Mach-O name, leading underscore included. NULL if absent on this OS build. |
| `HookServer(name, replacement, &original)` | Hooks a WindowServer symbol through Gum. The framework's own hooks are all installed from one table in `WXFHooks.c`; tweaks rarely need this. |

## Adding framework features

Each feature gets its own example tweak target, named `<Feature>Example`. Hooks go in the table
in `api/WXFHooks.c`, never installed from feature files. See `AGENTS.md` for the rules and for
how to ground new hooks in IDA.
