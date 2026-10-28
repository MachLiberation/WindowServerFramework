//
//  WXFDropdown.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Where a menu's dropdown appears. An app opens its menus itself, at the place MenuBarAgent told
// it the title is, and no other process may move its window (SLSMoveWindow answers 1000). A taskbar
// that shows an app's menus somewhere other than the title's place asks WindowServer to put the
// next dropdown where it wants it:
//
//   MenuBarAgent    WXFDropdownAnchor(x, y) just before it opens the menu (a client call; it
//                   needs nothing but the process's own SkyLight connection)
//   WindowServer    WXFDropdownSetAnchoringEnabled(true) once, when loading
//
// The request travels as a connection property whose name carries the numbers (the MIG routine
// _XSetConnectionProperty, which the framework hooks), so there is no other channel to set up.
// How and why: docs/taskbar-internals.md.

#ifndef WXFDROPDOWN_H
#define WXFDROPDOWN_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// WindowServer: lets clients move the next dropdown. Installs the hooks on first use (requires
/// SetupFramework to have been called).
/// @return false, changing nothing, if the hooks can't be installed on this OS build.
bool WXFDropdownSetAnchoringEnabled(bool enabled);

/// Any client: the next menu dropdown (a window at the pop-up menu level that appears with its top
/// edge within 16 points of `y`) is moved so its left edge is at `x`. Both are in global display
/// coordinates (origin at the top left of the main display, y down), the space of CGWindowList
/// bounds. The request is good for 1.5 seconds and for one window.
/// @return false if the request could not be sent.
bool WXFDropdownAnchor(double x, double y);

#ifdef __cplusplus
}
#endif

#endif
