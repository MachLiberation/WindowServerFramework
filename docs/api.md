# WindowServerExtensions API

This document defines the public API surface for WindowServerExtensions. The goal is to provide a stable, high-level customization API for developers without requiring them to reverse engineer internal WindowServer behavior.

The public API is intentionally designed to read like a C-facing interface, with names prefixed by `WSE`. The implementation may call private WindowServer or SLS internals behind the scenes, but the API itself should remain clean and understandable.

Examples:

- `WSEWorkspaceTransition.effect = WSETransitionEffectSlide;`
- `WSEWorkspaceTransition.effect = WSETransitionEffectCube;`
- `WSEWorkspaceTransition.effect = WSETransitionEffectWarp;`
- `WSEWindowAppearance.cornerRadius = 18.0;`
- `WSEWindowBorder.enabled = true;`
- `WSEWindowBorder.color = WSEColorSystemBlue;`
- `WSEWorkspaceLayout.spacing = 24.0;`

## WSETransitionEffect

The workspace transition effect enum defines the motion style used when switching or animating between workspaces.

| API | Type | What it does |
| --- | --- | --- |
| `WSETransitionEffectInstant` | enum | Instantly switches without animation. Useful for immediate transitions or accessibility modes. |
| `WSETransitionEffectSlide` | enum | Slides the workspace content in a direction. |
| `WSETransitionEffectFade` | enum | Fades one workspace into another. |
| `WSETransitionEffectZoom` | enum | Zooms the outgoing or incoming workspace for a cinematic feel. |
| `WSETransitionEffectCube` | enum | Simulates a cube-style 3D rotation between workspaces. |
| `WSETransitionEffectFlip` | enum | Flips the workspace as if it were a card or page. |
| `WSETransitionEffectPush` | enum | Pushes the incoming workspace across the screen. |
| `WSETransitionEffectCover` | enum | Covers the current workspace with the incoming one. |
| `WSETransitionEffectReveal` | enum | Reveals the next workspace beneath the current content. |
| `WSETransitionEffectSwipe` | enum | Swipes the workspace across the screen with a simple directional motion. |
| `WSETransitionEffectWarp` | enum | Distorts the workspace in a more dramatic, stylized motion. |
| `WSETransitionEffectMorph` | enum | Morphs the visual content between states with a fluid shape transition. |
| `WSETransitionEffectRipple` | enum | Produces a ripple-like distortion when switching workspaces. |
| `WSETransitionEffectBlur` | enum | Blurs the destination or source view during the transition. |
| `WSETransitionEffectGlide` | enum | Uses a soft, smooth pan or glide animation. |
| `WSETransitionEffectCustom` | enum | Allows a developer-defined transition implementation to be plugged in. |

## WSETransitionPreset

Predefined transition presets that combine effect, direction, duration, and motion profile into a ready-made configuration.

| API | Type | What it does |
| --- | --- | --- |
| `WSETransitionPresetNone` | enum | No transition; immediate switch. |
| `WSETransitionPresetDefault` | enum | Standard transition for general workspace switching. |
| `WSETransitionPresetSubtle` | enum | A soft and minimal animation with low visual intensity. |
| `WSETransitionPresetCinematic` | enum | A more dramatic effect suited to presentations or immersive layouts. |
| `WSETransitionPresetElastic` | enum | Springy motion with more bounce and energy. |
| `WSETransitionPresetSystem` | enum | Uses a system-native style that matches the current desktop experience. |

## WSEWorkspaceTransition

Controls how workspace changes animate and feel.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWorkspaceTransition.effect` | `WSETransitionEffect` | Chooses the workspace transition animation style. Example: `slide`, `cube`, `warp`, `fade`, or `instant`. |
| `WSEWorkspaceTransition.duration` | float | Sets the length of the transition animation in seconds. |
| `WSEWorkspaceTransition.easing` | enum | Chooses the motion curve for the animation, such as `linear`, `easeInOut`, or `spring`. |
| `WSEWorkspaceTransition.delay` | float | Adds a short delay before the transition starts. |
| `WSEWorkspaceTransition.enabled` | bool | Enables or disables the custom workspace transition behavior. |
| `WSEWorkspaceTransition.direction` | enum | Sets the direction of a directional transition, such as `left`, `right`, `up`, or `down`. |
| `WSEWorkspaceTransition.intensity` | float | Sets the strength or visual impact of the transition effect. |
| `WSEWorkspaceTransition.preset` | `WSETransitionPreset` | Applies a named preset configuration to the transition. |

## WSEWorkspaceLayout

Controls layout behavior for an individual workspace or desktop arrangement.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWorkspaceLayout.columns` | int | Sets the number of columns used by a workspace layout. |
| `WSEWorkspaceLayout.rows` | int | Sets the number of rows used by a workspace layout. |
| `WSEWorkspaceLayout.spacing` | float | Sets the spacing between tiles or windows in the workspace layout. |
| `WSEWorkspaceLayout.padding` | float | Sets the padding around the workspace content. |
| `WSEWorkspaceLayout.mode` | enum | Chooses the layout mode, such as `grid`, `stacked`, `floating`, or `custom`. |
| `WSEWorkspaceLayout.snapToGrid` | bool | Enables or disables snapping items to a visual grid. |

## WSEWindowAppearance

Controls high-level visual styling for windows and panes.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWindowAppearance.cornerRadius` | float | Sets the rounded corner radius for a window or workspace region. |
| `WSEWindowAppearance.shadow` | enum | Chooses a shadow style, such as `none`, `soft`, or `strong`. |
| `WSEWindowAppearance.backgroundColor` | color | Sets the default background color for a window or frame. |
| `WSEWindowAppearance.borderColor` | color | Sets the border color for a window or region. |
| `WSEWindowAppearance.borderWidth` | float | Sets the width of the border. |
| `WSEWindowAppearance.blur` | float | Controls the amount of blur applied to the window chrome or background effect. |
| `WSEWindowAppearance.opacity` | float | Sets the opacity of the window surface or chrome. |
| `WSEWindowAppearance.highlight` | color | Applies a highlight tint to the edge or top of a window. |

## WSEWindowBorder

Controls the border that appears around windows, tiles, or desktop regions.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWindowBorder.enabled` | bool | Enables or disables the border rendering for a window. |
| `WSEWindowBorder.width` | float | Sets the width of the border. |
| `WSEWindowBorder.size` | float | Alias for the border thickness, used for ergonomic configuration. |
| `WSEWindowBorder.color` | color | Sets the color of the border. |
| `WSEWindowBorder.borderColor` | color | Alias for `color`, included for readability in some codebases. |
| `WSEWindowBorder.style` | enum | Chooses a border style, such as `solid`, `dashed`, `glow`, or `none`. |
| `WSEWindowBorder.opacity` | float | Sets the transparency of the border. |
| `WSEWindowBorder.inset` | float | Controls how far the border sits inward from the edge of the window. |
| `WSEWindowBorder.radius` | float | Sets the border radius to match the corner curvature of the window. |
| `WSEWindowBorder.glow` | float | Controls the glow intensity around the border. |
| `WSEWindowBorder.shadow` | bool | Enables or disables a subtle shadow around the border edge. |

## WSEWindowCorner

Controls window corner geometry and related visual shaping.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWindowCorner.radius` | float | Sets the corner radius of the window surface. |
| `WSEWindowCorner.tl` | float | Sets the top-left corner radius independently. |
| `WSEWindowCorner.tr` | float | Sets the top-right corner radius independently. |
| `WSEWindowCorner.bl` | float | Sets the bottom-left corner radius independently. |
| `WSEWindowCorner.br` | float | Sets the bottom-right corner radius independently. |
| `WSEWindowCorner.enabled` | bool | Enables or disables custom corner shaping. |
| `WSEWindowCorner.smoothing` | float | Controls how smooth the corners appear when drawn. |
| `WSEWindowCorner.mask` | bool | Enables or disables masking to preserve the rounded shape. |

## WSEWindowBehavior

Controls how windows respond to interaction and workspace updates.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWindowBehavior.focusOnActivate` | bool | Specifies whether a window should take focus when activated. |
| `WSEWindowBehavior.animatedResize` | bool | Enables or disables animated resizing of a window. |
| `WSEWindowBehavior.dragThreshold` | float | Sets the threshold required before dragging begins. |
| `WSEWindowBehavior.doubleClickMaxDuration` | float | Sets the maximum time allowed for a double-click interaction. |
| `WSEWindowBehavior.snapToEdge` | bool | Enables or disables snapping a window to screen edges. |
| `WSEWindowBehavior.restoreAnimation` | enum | Chooses the animation style used when restoring a window. |

## WSEAnimationCurve

Reusable animation configuration shared by transitions and motion effects.

| API | Type | What it does |
| --- | --- | --- |
| `WSEAnimationCurve.type` | enum | Chooses the motion curve type, such as `linear`, `easeIn`, `easeOut`, `easeInOut`, or `spring`. |
| `WSEAnimationCurve.duration` | float | Controls the time spent for a given animation. |
| `WSEAnimationCurve.amplitude` | float | Sets the intensity of spring or bounce behavior. |
| `WSEAnimationCurve.period` | float | Sets the oscillation period for spring-based motion. |

## WSEWorkspaceEffect

High-level effects that can be applied to a workspace or desktop environment.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWorkspaceEffect.type` | enum | Selects an effect for the workspace, such as `none`, `slide`, `fade`, `blur`, `zoom`, `cube`, `warp`, or `custom`. |
| `WSEWorkspaceEffect.intensity` | float | Controls the strength of the applied effect. |
| `WSEWorkspaceEffect.enabled` | bool | Enables or disables the workspace effect. |
| `WSEWorkspaceEffect.duration` | float | Sets the duration of the effect animation. |

## WSEAccessibility

Accessibility-focused behavior to ensure WindowServer customization remains usable and inclusive.

| API | Type | What it does |
| --- | --- | --- |
| `WSEAccessibility.reduceMotion` | bool | Enables reduced-motion behavior when the user prefers less animation. |
| `WSEAccessibility.highContrast` | bool | Activates a high-contrast mode for window decorations and content. |
| `WSEAccessibility.focusOutline` | enum | Chooses how focus indicators are displayed around windows or controls. |
| `WSEAccessibility.voiceOverHints` | bool | Enables assistive announcements for custom workspace transitions and layout actions. |

## WSEGlobalSettings

Global API settings for configuring the framework at runtime.

| API | Type | What it does |
| --- | --- | --- |
| `WSEGlobalSettings.debugLogging` | bool | Enables or disables debug logging for WindowServer customization hooks. |
| `WSEGlobalSettings.usePrivateApis` | bool | Allows or disallows private-system implementation details when required. |
| `WSEGlobalSettings.defaultTransition` | enum | Sets the default workspace transition style used when no override is provided. |
| `WSEGlobalSettings.defaultAnimationCurve` | enum | Sets the default motion curve used by transitions and effects. |

## Implementation Notes

- All public symbols should be prefixed with `WSE`.
- The implementation may use WindowServer, SLS, QuartzCore, CoreGraphics, or equivalent underlying system APIs internally.
- Public APIs should remain high-level and avoid exposing raw WindowServer reverse-engineering details.
- This design is intentionally abstract so developers can customize behavior without needing intimate knowledge of private WindowServer internals.
- Transition effects should be additive and composable with direction, duration, easing, and intensity.
- Border and corner APIs should remain compatible with both simple global styles and per-window overrides.
- Future additions should remain additive and backwards-compatible when possible.

## Planned API Families

The following families are intended to be added as the framework matures:

- `WSEWorkspaceAnimation`
- `WSEWindowDecoration`
- `WSEAppOverride`
- `WSEDesktopBinding`
- `WSEScreenProfile`
- `WSEThemePalette`

This document is a design reference and should be treated as the public contract for the implementation work that follows.
