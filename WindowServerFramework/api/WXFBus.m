//
//  WXFBus.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// Client calls only: nothing here touches WindowServer's memory, it asks WindowServer through
// SkyLight, whose SLSSetConnectionProperty / SLSCopyConnectionProperty are the MIG routines
// _XSetConnectionProperty (the handler ignores the target argument and uses the caller's own
// connection) and _XGetConnectionProperty (target connection at +32, key at +44).

#include <WindowServerFramework/WXFBus.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <string.h>

typedef int (*MainConnectionFn)(void);
typedef CGError (*SetPropertyFn)(int cid, int target, CFStringRef key, CFTypeRef value);
typedef CGError (*CopyPropertyFn)(int cid, int target, CFStringRef key, CFTypeRef *value);
typedef CGError (*WindowOwnerFn)(int cid, uint32_t window, int *owner);

static struct {
    MainConnectionFn mainConnection;
    SetPropertyFn set;
    CopyPropertyFn copy;
    WindowOwnerFn owner;
} sky;

static bool Resolve(void) {
    if (!sky.mainConnection) {
        sky.set = (SetPropertyFn)dlsym(RTLD_DEFAULT, "SLSSetConnectionProperty");
        sky.copy = (CopyPropertyFn)dlsym(RTLD_DEFAULT, "SLSCopyConnectionProperty");
        sky.owner = (WindowOwnerFn)dlsym(RTLD_DEFAULT, "SLSGetWindowOwner");
        sky.mainConnection = (MainConnectionFn)dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    }
    return sky.mainConnection && sky.set && sky.copy && sky.owner;
}

uint32_t WXFBusMainConnection(void) {
    return Resolve() ? (uint32_t)sky.mainConnection() : 0;
}

bool WXFBusPublish(const char *key, CFPropertyListRef value) {
    if (!key || strlen(key) > 127 || !Resolve()) return false;
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    int cid = sky.mainConnection();
    CGError error = sky.set(cid, cid, name, value);
    CFRelease(name);
    return error == kCGErrorSuccess;
}

CFPropertyListRef WXFBusCopy(uint32_t connection, const char *key) {
    if (!key || !connection || !Resolve()) return NULL;
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef value = NULL;
    CGError error = sky.copy(sky.mainConnection(), (int)connection, name, &value);
    CFRelease(name);
    return error == kCGErrorSuccess ? value : NULL;
}

uint32_t WXFBusConnectionForPID(pid_t pid) {
    if (!Resolve()) return 0;
    uint32_t found = 0;
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    for (CFIndex i = 0; windows && i < CFArrayGetCount(windows) && !found; i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(windows, i);
        int32_t owner = 0;
        uint32_t number = 0;
        CFNumberRef pidValue = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        CFNumberRef numberValue = CFDictionaryGetValue(info, kCGWindowNumber);
        if (!pidValue || !numberValue) continue;
        CFNumberGetValue(pidValue, kCFNumberSInt32Type, &owner);
        if (owner != pid) continue;
        CFNumberGetValue(numberValue, kCFNumberSInt32Type, &number);
        int cid = 0;
        if (sky.owner(sky.mainConnection(), number, &cid) == kCGErrorSuccess && cid) found = (uint32_t)cid;
    }
    if (windows) CFRelease(windows);
    return found;
}
