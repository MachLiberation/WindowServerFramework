# WindowServerExtensions API

This document defines the public API surface for WindowServerExtensions. The goal is to provide a stable, high-level customization API for developers without requiring them to reverse engineer internal WindowServer behavior.

The public API is intentionally designed to read like a C-facing interface, with names prefixed by `WSE`. The implementation may call private WindowServer or SLS internals behind the scenes, but the API itself should remain clean and understandable.

Examples:

- `WSEWorkspaceTransition.effect = WSETransitionEffectSlide;`
- `WSEWindowAppearance.cornerRadius = 18.0;`
- `WSEWorkspaceLayout.spacing = 24.0;`

## WSEWorkspaceTransition

Controls how workspace changes animate and feel.

| API | Type | What it does |
| --- | --- | --- |
| `WSEWorkspaceTransition.effect` | enum | Chooses the workspace transition animation style. Example: `slide`, `fade`, `zoom`, or `custom`. |
| `WSEWorkspaceTransition.duration` | float | Sets the length of the transition animation in seconds. |
| `WSEWorkspaceTransition.easing` | enum | Chooses the motion curve for the animation, such as `linear`, `easeInOut`, or `spring`. |
| `WSEWorkspaceTransition.delay` | float | Adds a short delay before the transition starts. |
| `WSEWorkspaceTransition.enabled` | bool | Enables or disables the custom workspace transition behavior. |
| `WSEWorkspaceTransition.direction` | enum | Sets the direction of a directional transition, such as `left`, `right`, `up`, or `down`. |

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
| `WSEWorkspaceEffect.type` | enum | Selects an effect for the workspace, such as `none`, `slide`, `fade`, `blur`, or `zoom`. |
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
