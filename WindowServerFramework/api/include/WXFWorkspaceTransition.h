//Created by Salty on 10/26/26.

#ifndef WXFWORKSPACETRANSITION_H
#define WXFWORKSPACETRANSITION_H

#include <stdint.h>
#include <stdbool.h>
#include <WindowServerFramework/WXFBase.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __has_attribute(cf_returns_retained)
#define WXF_RETURNS_RETAINED __attribute__((cf_returns_retained))
#else
#define WXF_RETURNS_RETAINED
#endif

typedef struct __WXFWorkspaceTransition *WXFWorkspaceTransitionRef;

typedef uint32_t WXFTransitionEffect;
enum {
    /// A sliding space transition, the system default as of macOS Sequoia.
    WXFTransitionEffectSlide = 0,
    /// A cube space transition, similar to KDE's cube.
    WXFTransitionEffectCube,
    /// A no-motion fade transition.
    WXFTransitionEffectFade,
    /// A warp transition which warps and moves the spaces.
    WXFTransitionEffectWarp,
    /// An immediate transition with no animation.
    WXFTransitionEffectImmediate
};

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

#ifdef __cplusplus
}
#endif

#endif /* WXFWORKSPACETRANSITION_H */
