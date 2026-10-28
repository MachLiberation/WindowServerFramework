//
//  WXFDock.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Whether the Dock takes space from the work area. The Dock tells WindowServer where it sits
// (SLSSetDockRectWithReason) and every app reads that back and subtracts it from
// NSScreen.visibleFrame, so windows zoom, tile and open clear of it. With the rectangle reported as
// empty, nothing is left clear: a Dock that is still visible then floats over the windows.
//
// This only changes the space it reserves. Hiding the Dock itself is the user's autohide setting
// (System Settings > Desktop & Dock); a tweak that replaces the Dock (a taskbar) turns the first
// off here and asks the user for the second.
//
// Global, last call wins. Call from WindowServer's main thread or from a hook.

#ifndef WXFDOCK_H
#define WXFDOCK_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Whether the Dock's rectangle is passed on to clients. Default true. Installs the WindowServer
/// hooks the first time it is called with false (requires SetupFramework to have been called).
/// Apps pick the change up the next time they read the rectangle, which is when the Dock next
/// reports one; a tweak that sets it while loading is ahead of the Dock and every app.
/// @return false, changing nothing, if the hooks can't be installed on this OS build.
bool WXFDockSetReservesSpace(bool reserves);

bool WXFDockGetReservesSpace(void);

#ifdef __cplusplus
}
#endif

#endif
