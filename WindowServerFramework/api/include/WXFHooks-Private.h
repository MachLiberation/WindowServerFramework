//
//  WXFHooks-Private.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Every hook the framework puts into WindowServer is installed from WXFHooks.c, and only there.
// A feature (drag, space switching, window close, ...) defines its replacement functions and
// original-function pointers in its own file with external linkage, then lists them in the table
// in WXFHooks.c under a group. Nothing else calls HookServer.

#ifndef WXFHOOKS_PRIV_H
#define WXFHOOKS_PRIV_H

#include <stdbool.h>

typedef enum {
    /// The drag events (WXFDrag.m). Installed as soon as SetupFramework has run.
    WXFHookGroupDrag,
    /// The compositor hooks behind drag shaders (WXFDragShader.m). Installed on first use.
    WXFHookGroupDragShader,
    /// Key, button and gesture events (WXFEvent.m). Installed on first use.
    WXFHookGroupEventKeys,
    /// Mouse move, drag and scroll events (WXFEvent.m). Installed on first use.
    WXFHookGroupEventPointer,
    /// The menu bar's rectangle (WXFMenuBar.m). Installed on first use.
    WXFHookGroupMenuBar,
    /// Which CAContext each app window hosts (WXFCAContextRetriever.m). Installed as soon as
    /// SetupFramework has run, so the map is complete for windows made afterwards.
    WXFHookGroupCAContext,
    WXFHookGroupCount
} WXFHookGroup;

/// Installs every hook in `group`, or none of them if any symbol is missing on this OS build.
/// Idempotent. Returns false (and installs nothing) until SetupFramework has been called, or if
/// the group can't be installed.
bool WXFHooksInstall(WXFHookGroup group);

/// Installs the groups that go in at startup. Called by SetupFramework.
void WXFHooksInstallAll(void);

#endif
