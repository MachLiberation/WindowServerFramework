//Created by Salty on 10/26/26.

#ifndef WXFWORKSPACETRANSITION_H
#define WXFWORKSPACETRANSITION_H

#include <stdint.h>
#include <stdbool.h>
#include <WindowServerFramework/WXFBase.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __WXFWorkspaceTransition;
typedef struct __WXFWorkspaceTransition *WXFWorkspaceTransitionRef;

typedef enum {
    /// A sliding space transition, the system default as of macOS Sequoia.
    WXFTransitionEffectSlide = 0,
    /// A cube space transition, similar to KDE's cube.
    WXFTransitionEffectCube,
    /// A no-motion fade transition.
    WXFTransitionEffectFade,
    /// A warp transition which warps and moves the spaces.
    WXFTransitionEffectWarp,
    /// An immediate transition with no animation.
    WXFTransitionEffectImmediate,
    
} WXFTransitionEffect;

typedef enum {
    /// Ease in, ease out.
    WXFTransitionEasingModeEaseInEaseOut,
    /// Spring motion curve.
    WXFTransitionEasingModeSpring,
    /// Linear motion curve.
    WXFTransitionEasingModeLinear
} WXFTransitionEasingMode;

typedef enum {
    /// Transitions move upwards towards the top of the screen, in AppKit coordinate space.
    WXFTransitionDirectionUp,
    /// Transitions move downwards towards the bottom of the screen, in AppKit coordinate space.
    WXFTransitionDirectionDown,
    /// Transitions move to the left.
    WXFTransitionDirectionLeft,
    /// Transitions move to the right.
    WXFTransitionDirectionRight
} WXFTransitionDirection;

/// Returns the type identifier for WXFWorkspaceTransition objects.
WXFTypeID WXFWorkspaceTransitionGetTypeID(void);

/// Creates a new workspace transition. Returned +1 retained; release with WXFRelease.
WXF_RETURNS_RETAINED
WXFWorkspaceTransitionRef WXFWorkspaceTransitionCreate(void);

/// Sets the transition effect.
/// @param transition The workspace transition being built.
/// @param effect The effect to use.
/// @return true on success, false if the effect value is invalid.
bool WXFWorkspaceTransitionSetEffect(WXFWorkspaceTransitionRef transition,
                                     WXFTransitionEffect effect);

/// Returns the transition's current effect.
WXFTransitionEffect WXFWorkspaceTransitionGetEffect(WXFWorkspaceTransitionRef transition);

/// Sets the duration of the transition.
/// @param transition The workspace transition being built.
/// @param nanoseconds The duration of the transition in nanoseconds.
/// @return true on success, false if the duration or transition is invalid.
bool WXFWorkspaceTransitionSetDuration(WXFWorkspaceTransitionRef transition,
                                       float nanoseconds);

/// Returns the transition's duration.
float WXFWorkspaceTransitionGetDuration(WXFWorkspaceTransitionRef transition);

/// Sets the easing of the transition.
/// @param transition The workspace transition being built.
/// @param mode The ease mode to use with the transition.
/// @return true on success, false if the mode or transition is invalid.
bool WXFWorkspaceTransitionSetEasing(WXFWorkspaceTransitionRef transition,
                                     WXFTransitionEasingMode mode);

/// Returns the transition's easing mode.
WXFTransitionEasingMode WXFWorkspaceTransitionGetEasing(WXFWorkspaceTransitionRef transition);

/// Sets the delay (if any) of the transition.
/// @param transition The workspace transition being built.
/// @param nanoseconds The delay to set before the transition begins.
/// @return true on success, false if the duration or transition is invalid.
bool WXFWorkspaceTransitionSetDelay(WXFWorkspaceTransitionRef transition,
                                    float nanoseconds);

/// Returns the delay (if any) for the transition.
float WXFWorkspaceTransitionGetDelay(WXFWorkspaceTransitionRef transition);

/// Sets whether the transition changes are enabled for the window server.
/// @param transition The transition to enable.
/// @param enabled Whether the transition changes are enabled.
/// @return true on success, false if the transition is invalid.
bool WXFWorkspaceTransitionSetEnabled(WXFWorkspaceTransitionRef transition,
                                      bool enabled);

/// Returns whether the transition is active/enabled or not.
bool WXFWorkspaceTransitionGetEnabled(WXFWorkspaceTransitionRef transition);

/// Sets the direction of motion for the transition.
/// @param transition The transition being built.
/// @param direction The direction the transition will move in.
/// @return true on success, false if the direction is invalid.
bool WXFWorkspaceTransitionSetDirection(WXFWorkspaceTransitionRef transition,
                                        WXFTransitionDirection direction);

/// Returns the set direction the transition will move in.
WXFTransitionDirection WXFWorkspaceTransitionGetDirection(WXFWorkspaceTransitionRef transition);

/// Sets the intensity of the transition effect.
/// @param transition The transition being built.
/// @param intensity The intensity of the transition. Valid range is > 0, in percent. 100% is normal intensity, greater than or less than is more/less intense.
/// @return true on success, false if the intensity is invalid.
bool WXFWorkspaceTransitionSetIntensity(WXFWorkspaceTransitionRef transition,
                                        float intensity);

/// Returns the intensity of the transition. Valid range is > 0, in percent. 100% is normal intensity, greater than or less than is more/less intense.
float WXFWorkspaceTransitionGetIntensity(WXFWorkspaceTransitionRef transition);
#ifdef __cplusplus
}
#endif

#endif /* WXFWORKSPACETRANSITION_H */
