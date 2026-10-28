//
//  WXFMenuBar.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// How tall the menu bar is, and whether it can hide. The rectangle comes from one WindowServer
// function (see docs/menubar-internals.md), so the bar window, the part of the screen windows
// can't be dragged into, the status items, the height MenuBarAgent lays its contents out for and
// the rectangle clients are told about all follow the new height together.
//
// The height is also the work area. Clients (NSScreen.visibleFrame, the zoom button, new window
// placement) take the top inset from the display's menu bar height and, on a notched display,
// from the notch rectangle; both are produced when WindowServer evaluates the display's parts, so
// the framework adjusts them there (docs/taskbar-internals.md).
//
// The settings are global (the bar is one thing). Where two tweaks disagree, the later call wins.
// Call from WindowServer's main thread or from a hook; a change shows once the bar has rebuilt.

#ifndef WXFMENUBAR_H
#define WXFMENUBAR_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The bar's height in points. 0 (the default) keeps the system's height: 30, or the notch's
/// plus one on a notched display. Installs the WindowServer hooks the first time (requires
/// SetupFramework to have been called), and rebuilds the bar.
///
/// The bar's rectangle follows at once. The work area (the inset clients leave at the top of the
/// display) is written when WindowServer next evaluates a display's parts, which is at startup, on
/// a display or mode change, and on plugging a display: a tweak that sets the thickness while
/// loading gets both, one that changes it later gets the bar now and the work area then. On a
/// notched display the notch rectangle clients see is made as tall as the bar (less one point), so
/// the safe area and the areas beside the notch grow with it.
/// @return false, changing nothing, if the bounds hook can't be installed on this OS build or the
///         value is negative.
bool WXFMenuBarSetThickness(double points);

double WXFMenuBarGetThickness(void);

/// Keeps the bar fully revealed. Normally the bar slides away in full screen and when the user
/// chose to hide it automatically; with this on, every request to reveal it less than fully is
/// raised to "fully", so it stays put. Default off.
/// @return false, changing nothing, if the hook can't be installed on this OS build.
bool WXFMenuBarSetAlwaysVisible(bool visible);

bool WXFMenuBarGetAlwaysVisible(void);

#ifdef __cplusplus
}
#endif

#endif
