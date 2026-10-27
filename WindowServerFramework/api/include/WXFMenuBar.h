//
//  WXFMenuBar.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// How tall the menu bar is. The rectangle comes from one WindowServer function (see
// docs/menubar-internals.md), so the bar window, the part of the screen windows can't be dragged
// into, the status items and the rectangle clients are told about all follow the new height
// together.
//
// The setting is global (the bar is one thing). Where two tweaks disagree, the later call wins.
// Call from WindowServer's main thread or from a hook; the change shows once the bar has rebuilt.

#ifndef WXFMENUBAR_H
#define WXFMENUBAR_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The bar's height in points. 0 (the default) keeps the system's height: 30, or the notch's on a
/// notched display. The status items and app menus are drawn for the system height, so values far
/// from it will clip or leave gaps. Installs the WindowServer hook the first time (requires
/// SetupFramework to have been called), and rebuilds the bar.
/// @return false, changing nothing, if the hook can't be installed on this OS build or the value
///         is negative.
bool WXFMenuBarSetThickness(double points);

double WXFMenuBarGetThickness(void);

#ifdef __cplusplus
}
#endif

#endif
