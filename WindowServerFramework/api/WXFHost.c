//
//  WXFHost.c
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//

#include <WindowServerFramework/WXFHost.h>
#include <stdlib.h>
#include <string.h>

WXFHost WXFGetHost(void) {
    static WXFHost host;
    static bool known;
    if (!known) {
        const char *name = getprogname();
        if (name && strcmp(name, "WindowServer") == 0) host = WXFHostWindowServer;
        else if (name && strcmp(name, "MenuBarAgent") == 0) host = WXFHostMenuBarAgent;
        else host = WXFHostOther;
        known = true;
    }
    return host;
}
