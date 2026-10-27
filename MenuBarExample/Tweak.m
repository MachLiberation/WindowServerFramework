//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Makes the menu bar 36 points tall. Control + Option + Command + [ and ] make it thinner and
// thicker, 4 points at a time, and Control + Option + Command + \ goes back to the system's
// height.
//
// All of the work is in the framework (WXFMenuBar); this file only chooses the height and listens
// for the keys.

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFEvent.h>
#include <WindowServerFramework/WXFMenuBar.h>
#include <os/log.h>

enum { kVKRightBracket = 30, kVKLeftBracket = 33, kVKBackslash = 42 };

static const double kSystemHeight = 30.0;   // what thickness 0 means without a notch
static const double kInitial = 36.0;
static const double kStep = 4.0;

static WXFEventDisposition HandleKey(WXFEventRef event, void *info) {
    (void)info;
    const uint32_t chord = WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand;
    uint32_t mods = WXFEventGetFlags(event) &
                    (WXFEventFlagShift | WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand);
    if (mods != chord) return WXFEventDispositionPass;

    uint16_t key = WXFEventGetKeyCode(event);
    if (key != kVKLeftBracket && key != kVKRightBracket && key != kVKBackslash)
        return WXFEventDispositionPass;
    // Act on the press and swallow the release, so the app underneath never sees half a chord.
    if (WXFEventGetType(event) == WXFEventTypeKeyDown) {
        double thickness = WXFMenuBarGetThickness();
        double current = thickness > 0 ? thickness : kSystemHeight;
        if (key == kVKLeftBracket)
            WXFMenuBarSetThickness(current > kStep ? current - kStep : current);
        else if (key == kVKRightBracket)
            WXFMenuBarSetThickness(current + kStep);
        else
            WXFMenuBarSetThickness(0);
    }
    return WXFEventDispositionConsume;
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);

    bool set = WXFMenuBarSetThickness(kInitial);
    WXFEventHandlerID handler = WXFEventAddHandler(WXFEventTypeKeyDown | WXFEventTypeKeyUp, HandleKey, NULL);
    os_log(OS_LOG_DEFAULT, "WXF menubar example: loaded, thickness set %d, key handler %u", set, handler);
}
