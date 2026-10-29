//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// card0, read-only (WXFCard.h): logs the card's connectors and their modes once WindowServer has
// brought its displays up, and every hotplug it processes afterwards. It changes nothing. Read the
// result with `scripts/deploy.sh --logs` or
//   /usr/bin/log show --last 10m --process WindowServer | grep WXF

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFCard.h>
#include <WindowServerFramework/WXFMisc.h>
#include <os/log.h>

static const char *TypeName(WXFConnectorType type) {
    switch (type) {
        case WXFConnectorTypeInternal: return "internal";
        case WXFConnectorTypeExternal: return "external";
        case WXFConnectorTypeVirtual:  return "virtual";
        case WXFConnectorTypeDFR:      return "dfr";
        default:                       return "unknown";
    }
}

static void Dump(const char *why) {
    WXFConnectorInfo connectors[16];
    size_t total = WXFCardCopyConnectors(connectors, 16);
    os_log(OS_LOG_DEFAULT, "WXF card0 (%{public}s): %zu connector(s)", why, total);
    for (size_t i = 0; i < total && i < 16; i++) {
        const WXFConnectorInfo *c = &connectors[i];
        uint64_t previous = 0, interval = 0;
        WXFCardGetVBlank(c->id, &previous, &interval);
        os_log(OS_LOG_DEFAULT,
               "WXF card0: connector %u %{public}s '%{public}s' id=%{public}s enabled=%d blanked=%d "
               "managed=%d bounds=(%.0f,%.0f %.0fx%.0f) native=%.0fx%.0f modes=%u current=%u vblank=%llu",
               c->id, TypeName(c->type), c->name, c->uniqueID, c->enabled, c->blanked, c->managed,
               c->bounds.origin.x, c->bounds.origin.y, c->bounds.size.width, c->bounds.size.height,
               c->nativeSize.width, c->nativeSize.height, c->modeCount, c->currentModeID, interval);
        WXFModeInfo modes[256];
        size_t modeTotal = WXFCardCopyModes(c->id, modes, 256);
        for (size_t m = 0; m < modeTotal && m < 256; m++)
            os_log(OS_LOG_DEFAULT, "WXF card0:   mode %u %ux%u (%ux%u pt, %.1fx) %.2f Hz%{public}s%{public}s",
                   modes[m].id, modes[m].width, modes[m].height, modes[m].pointWidth, modes[m].pointHeight,
                   modes[m].scale, modes[m].refreshRate, modes[m].isDefault ? " default" : "",
                   modes[m].isCurrent ? " current" : "");
    }
}

static void Hotplug(WXFConnectorID connector, bool connected, WXFHotplugReason reason, bool handled, void *info) {
    os_log(OS_LOG_DEFAULT, "WXF card0: hotplug connector %u %{public}s reason=%d handled=%d",
           connector, connected ? "in" : "out", (int)reason, handled);
}

// WindowServer loads tweaks before it has made its displays; look again until they are there.
static void Poll(void *info, double now) {
    intptr_t attempt = (intptr_t)info;
    if (WXFCardAvailable()) {
        WXFConnectorInfo probe[1];
        if (WXFCardCopyConnectors(probe, 1) > 0) { Dump("ready"); return; }
    }
    if (attempt >= 24) { os_log(OS_LOG_DEFAULT, "WXF card0: no connectors after %ld tries", (long)attempt); return; }
    WXFScheduleCallback(Poll, (void *)(attempt + 1), WXFCurrentTime() + 5);
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);
    if (!WXFCardAddHotplugObserver(Hotplug, NULL))
        os_log(OS_LOG_DEFAULT, "WXF card0: hotplug observer not installed");
    WXFScheduleCallback(Poll, (void *)0, WXFCurrentTime() + 5);
}
