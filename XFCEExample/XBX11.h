//
//  XBX11.h
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// The smallest X11 client that lets a Cocoa app put windows on XFCEExample's X server: connect over
// loopback TCP, authenticate with the MIT-MAGIC-COOKIE, create/map/resize/destroy windows, set their
// properties, upload pixels with PutImage, and read events.
//
// It speaks the wire protocol itself instead of using libX11: the tweak loads into arm64e apps, and
// XQuartz's libraries have no arm64e slice, so they could not be loaded there.

#ifndef XBX11_H
#define XBX11_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

// The event kinds the bridge reads (X protocol event codes).
enum {
    XBXKeyPress = 2, XBXKeyRelease = 3, XBXButtonPress = 4, XBXButtonRelease = 5, XBXMotionNotify = 6,
    XBXEnterNotify = 7, XBXLeaveNotify = 8, XBXFocusIn = 9, XBXFocusOut = 10, XBXExpose = 12,
    XBXConfigureNotify = 22, XBXClientMessage = 33,
};

typedef struct {
    uint8_t type;
    uint8_t detail;           // keycode or button
    uint32_t window;          // the window the event is for
    int16_t x, y;             // event-window coordinates (ConfigureNotify: the window's own x, y)
    uint16_t width, height;   // ConfigureNotify, Expose
    uint16_t state;           // modifier and button mask
    uint32_t atom;            // ClientMessage: the message type
    uint32_t data0;           // ClientMessage: first data word
} XBXEvent;

// Connects to $WXF_X_DISPLAY (default localhost:7) with the cookie in $WXF_X_AUTHORITY (default
// /private/tmp/wxf-x11/Xauthority) and interns the atoms below. False if the X server isn't there.
bool XBXConnect(void);
// Why the last XBXConnect failed.
const char *XBXLastError(void);
int XBXFd(void);
void XBXClose(void);

typedef struct {
    uint32_t root;
    uint16_t width, height;   // the screen, in pixels
    uint8_t depth;
    uint8_t minKeycode;
} XBXScreen;
XBXScreen XBXGetScreen(void);

// Atoms interned at connect time.
extern uint32_t XBXAtomWMProtocols, XBXAtomWMDeleteWindow, XBXAtomWMName, XBXAtomNetWMName,
    XBXAtomUTF8String, XBXAtomWMClass, XBXAtomWMNormalHints, XBXAtomString, XBXAtomCardinal,
    XBXAtomNetWMPid, XBXAtomWMTransientFor, XBXAtomWindow, XBXAtomAtom;

uint32_t XBXCreateWindow(int x, int y, int width, int height);
void XBXDestroyWindow(uint32_t window);
void XBXMapWindow(uint32_t window);
void XBXResizeWindow(uint32_t window, int width, int height);
// WM_NAME takes Latin-1; _NET_WM_NAME the same title in UTF-8.
void XBXSetTitle(uint32_t window, const char *latin1, const char *utf8);
void XBXSetClass(uint32_t window, const char *instance, const char *cls);
void XBXSetDeleteProtocol(uint32_t window);
void XBXSetTransientFor(uint32_t window, uint32_t parent);
// min/max 0 = unconstrained on that axis; passing both axes 0 clears the hint.
void XBXSetSizeHints(uint32_t window, int minW, int minH, int maxW, int maxH);
void XBXSetPid(uint32_t window, uint32_t pid);

// A graphics context for `window` (PutImage needs one).
uint32_t XBXCreateGC(uint32_t window);
void XBXFreeGC(uint32_t gc);
// `bgrx` is `width` x `rows` 32-bit pixels, tightly packed, drawn at (0, y) of the window.
// Split into requests small enough for a server without BIG-REQUESTS.
void XBXPutImage(uint32_t window, uint32_t gc, const uint32_t *bgrx, int width, int y, int rows);

void XBXFlush(void);
// Reads whatever has arrived and calls `handle` for each event. Returns false when the connection
// is closed (the X server went away).
bool XBXReadEvents(void (^handle)(const XBXEvent *event));

#endif
