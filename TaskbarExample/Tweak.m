//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// A 50 point taskbar along the top of every display, in place of the menu bar and the Dock.
//
// It is one tweak loaded into two processes (the whitelist names both):
//
//   WindowServer   makes the bar 50 points tall, keeps it revealed (also in full screen and when
//                  "automatically hide the menu bar" is on), and stops the Dock's rectangle from
//                  being taken off the work area. All of this is the framework (WXFMenuBar,
//                  WXFDock): windows zoom, tile and open below the bar. It also moves an app's
//                  menu dropdown under the icon it was opened from (WXFDropdown).
//   MenuBarAgent   draws the running apps over the bar's app menu strip (TBAgent). The status
//                  items are the system's own, so the tray is the real one.
//
// Any other process the whitelist names is an app whose full menu the agent shows (TBAppMenu):
// scripts/deploy.sh lists the apps.
//
// The Dock itself is not part of either process; scripts/deploy.sh --hide-dock turns on its
// autohide so it stays out of the way.

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFDock.h>
#include <WindowServerFramework/WXFDropdown.h>
#include <WindowServerFramework/WXFHost.h>
#include <WindowServerFramework/WXFMenuBar.h>
#include <os/log.h>
#import "TBAgent.h"
#import "TBAppMenu.h"

static const double kBarHeight = 50.0;

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);

    switch (WXFGetHost()) {
    case WXFHostWindowServer: {
        bool thickness = WXFMenuBarSetThickness(kBarHeight);
        bool visible = WXFMenuBarSetAlwaysVisible(true);
        bool dock = WXFDockSetReservesSpace(false);
        bool dropdown = WXFDropdownSetAnchoringEnabled(true);
        os_log(OS_LOG_DEFAULT, "WXF taskbar: WindowServer half loaded, thickness %d, always visible %d, dock space %d, dropdown %d",
               thickness, visible, dock, dropdown);
        break;
    }
    case WXFHostMenuBarAgent:
        TBAgentStart(kBarHeight);
        os_log(OS_LOG_DEFAULT, "WXF taskbar: MenuBarAgent half loaded");
        break;
    default:
        // An app the whitelist names: share its menu with the agent.
        TBAppMenuStart();
        break;
    }
}
