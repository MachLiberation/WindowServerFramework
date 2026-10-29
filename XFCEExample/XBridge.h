//
//  XBridge.h
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// The app half of XFCEExample: a Cocoa app that was started with WXF_XBRIDGE=1 (xfce-open.sh does
// that) gets each of its windows as a window on the X session. See XBridge.m.

#ifndef XBRIDGE_H
#define XBRIDGE_H

// Connects to the X server and starts mirroring windows. Does nothing in an app that wasn't started
// for the X session, or when the X server isn't there (the app then runs on the Mac as usual).
void XBridgeStart(void);

#endif
