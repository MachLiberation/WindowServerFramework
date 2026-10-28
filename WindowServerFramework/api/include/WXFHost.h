//
//  WXFHost.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Which process a tweak was loaded into. A tweak is one dylib that Ammonia loads into every
// process its whitelist names, so a tweak that works on both sides of a feature (WindowServer
// for geometry, MenuBarAgent for the content drawn in it) asks where it is and branches.
//
// The framework only hooks WindowServer: SetupFramework leaves the WindowServer hooks out of any
// other host, so a tweak in MenuBarAgent gets the interceptor for its own use and nothing else.

#ifndef WXFHOST_H
#define WXFHOST_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    /// Any process the framework has no special knowledge of.
    WXFHostOther = 0,
    /// /System/Library/Frameworks/CoreGraphics.framework/Resources/WindowServer: the compositor
    /// and the owner of every WXF* feature that hooks SkyLight.
    WXFHostWindowServer,
    /// /System/Library/CoreServices/MenuBarAgent.app: the process that draws the menu bar's
    /// contents (app menus, status items) in its own windows. See docs/taskbar-internals.md.
    WXFHostMenuBarAgent,
} WXFHost;

/// The process this code is running in (decided once, from the process name).
WXFHost WXFGetHost(void);

#ifdef __cplusplus
}
#endif

#endif
