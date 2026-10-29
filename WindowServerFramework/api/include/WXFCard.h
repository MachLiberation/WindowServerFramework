//
//  WXFCard.h
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// WindowServer's display bring-up, seen the way Linux shows it through /dev/dri/card0: one card
// that owns connectors (the displays), each with a list of modes, a connected/disconnected state
// that changes at hotplug, a power state, and a way to put a framebuffer on it.
//
//   DRM                       here
//   ---                       ----
//   drmModeGetResources       WXFCardCopyConnectors
//   drmModeGetConnector       WXFCardGetConnector, WXFCardCopyModes
//   hotplug uevent            WXFCardAddHotplugObserver
//   (debugfs force=on/off)    WXFCardSetConnected
//   DPMS property             WXFCardSetBlanked, WXFCardSetEnabled
//   drmModeSetCrtc (mode)     WXFCardSetMode
//   drmModePageFlip           WXFCardPresent
//   (master / atomic commit)  WXFCardSetUpdatesDisabled, WXFCardGetScanout
//   vblank timestamps         WXFCardGetVBlank
//
// A connector is a CAWindowServerDisplay, one per attached panel, external display, Touch Bar or
// virtual display (the ids are the display ids WindowServer itself uses). The card is not a
// device node and does not replace WindowServer's own bring-up (the AppleInternal/External/DFR
// backends of -[CAWindowServer _detectDisplays]): it exposes what bring-up produced, and the
// controls WindowServer has for it. See docs/display-internals.md for what each call maps to.
//
// Everything here is meant for WindowServer's main thread (hooks and WXFScheduleCallback run
// there). Calls are safe before the displays exist: they report an empty card.

#ifndef WXFCARD_H
#define WXFCARD_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A connector's id: the display id WindowServer uses everywhere (CGDirectDisplayID's value).
typedef uint32_t WXFConnectorID;

/// -[CAWindowServerDisplay displayType], by name.
typedef enum {
    WXFConnectorTypeInternal = 0,   ///< The built-in panel.
    WXFConnectorTypeExternal = 1,
    WXFConnectorTypeVirtual  = 3,
    WXFConnectorTypeDFR      = 4,   ///< Touch Bar.
    WXFConnectorTypeUnknown  = -1,
} WXFConnectorType;

typedef struct {
    WXFConnectorID   id;
    WXFConnectorType type;
    /// WindowServer is driving this connector (-[CAWindowServerDisplay enabled]).
    bool             enabled;
    /// The display is blanked (-[CAWindowServerDisplay isBlanked]).
    bool             blanked;
    /// QuartzCore gave it a unique id: set once the panel is identified, which is what
    /// WindowServer checks before it treats a display as connected.
    bool             hasUniqueID;
    /// It is in WindowServer's hardware display list (CAWSManager +1392), which is where the modes
    /// are read from. Only managed connectors have modes.
    bool             managed;
    /// Global display space, in points (infinite origin if the display has no state).
    CGRect           bounds;
    CGSize           nativeSize;     ///< Pixels.
    CGSize           physicalSize;   ///< Millimetres, 0 if unknown.
    char             name[64];
    char             uniqueID[64];
    uint32_t         modeCount;      ///< 0 unless managed.
    uint32_t         currentModeID;  ///< A WXFModeInfo.id; meaningful only if modeCount > 0.
} WXFConnectorInfo;

typedef struct {
    uint32_t id;               ///< WindowServer's mode id (what the configuration engine takes).
    uint32_t width, height;    ///< Pixels scanned out.
    uint32_t pointWidth, pointHeight;
    float    scale;            ///< Pixels per point.
    float    refreshRate;      ///< Hz.
    bool     isDefault;
    bool     isCurrent;
} WXFModeInfo;

// --- The card ---------------------------------------------------------------------------------

/// Whether the card exists: QuartzCore's window server is running and WindowServer's display
/// manager has been created. False early in startup.
bool WXFCardAvailable(void);

/// Writes up to `capacity` connectors into `out` and returns how many there are in all (which can
/// be more than `capacity`, like snprintf). `out` may be NULL to just count.
size_t WXFCardCopyConnectors(WXFConnectorInfo *out, size_t capacity);

/// The connector with this id. False if there is none.
bool WXFCardGetConnector(WXFConnectorID connector, WXFConnectorInfo *out);

/// Writes up to `capacity` modes of a managed connector into `out` and returns how many it has in
/// all (0 if the connector is unknown or unmanaged). A connector in a mirror set has a second,
/// mirroring list in WindowServer; this is the ordinary one.
size_t WXFCardCopyModes(WXFConnectorID connector, WXFModeInfo *out, size_t capacity);

// --- Modeset ----------------------------------------------------------------------------------

/// Changes the connector's current mode through WindowServer's configuration engine
/// (WS::Displays::configuration_engine::config_current_mode, which edits the session's display
/// configuration and commits it with an immediate reconfigure). `mode` is a WXFModeInfo.id of that
/// connector. The change is made on WindowServer's main thread shortly after this returns, so read
/// WXFCardGetConnector's currentModeID afterwards to see it land. WindowServer saves the resulting
/// configuration the way it does for any mode change, so a mode set here is what the display comes
/// back in after a restart: set the old one again to undo it.
/// @return false, doing nothing, if the connector is unknown, not enabled and identified, has no
///         such mode, or the configuration engine is in the middle of a change. True also if the mode
///         is already current (nothing is scheduled then).
bool WXFCardSetMode(WXFConnectorID connector, uint32_t mode);

// --- Hotplug ----------------------------------------------------------------------------------

/// Who reported the hotplug (WindowServer's own names for them: CA, PM, SP, API).
typedef enum {
    WXFHotplugReasonDisplay   = 1,   ///< The display itself, through QuartzCore.
    WXFHotplugReasonPower     = 2,
    WXFHotplugReasonSoftPlug  = 3,
    WXFHotplugReasonInjected  = 4,   ///< The client API, which WXFCardSetConnected uses.
} WXFHotplugReason;

/// Called after WindowServer has processed a hotplug event for a hardware connector. `handled` is
/// WindowServer's own result (false for a connect it had to undo, or an unknown id). Runs on the
/// thread WindowServer processes hotplug on, with no framework lock held.
typedef void (*WXFCardHotplugFunction)(WXFConnectorID connector, bool connected,
                                       WXFHotplugReason reason, bool handled, void *info);

/// Returns an observer id for WXFCardRemoveObserver, or 0 if the WindowServer function can't be
/// hooked on this OS build (requires SetupFramework to have been called).
uint32_t WXFCardAddHotplugObserver(WXFCardHotplugFunction function, void *info);
void     WXFCardRemoveObserver(uint32_t observer);

/// Makes WindowServer process a connect or disconnect for a managed connector, the way the
/// client-API soft-plug does (CAWSManager::inject_hotplug, run on the main thread). It does not
/// touch the hardware. Disconnecting the only display leaves the session with none.
/// @return false, doing nothing, if the connector is unknown, unmanaged or a Touch Bar.
bool WXFCardSetConnected(WXFConnectorID connector, bool connected);

// --- Power ------------------------------------------------------------------------------------

/// -[CAWindowServerDisplay setBlanked:]. Blanking keeps the connector in the configuration.
bool WXFCardSetBlanked(WXFConnectorID connector, bool blanked);

/// -[CAWindowServerDisplay setEnabled:], which is WindowServer's display state change: a disabled
/// connector is not rendered to.
bool WXFCardSetEnabled(WXFConnectorID connector, bool enabled);

// --- Frames -----------------------------------------------------------------------------------

/// Puts an IOSurface on a managed connector with WindowServer's own present path
/// (SLCADisplay::present_iosurface). The connector must be enabled and identified; on an ordinary
/// display the surface must be exactly the size of the connector's surface (WindowServer asserts
/// it). `vsync` asks for the present to be synchronised to vblank and the compositor flushed
/// before returning. WindowServer's own compositing is not paused by this (see
/// WXFCardSetUpdatesDisabled); what a frame presented while it is also drawing does is not tested.
/// Main thread only.
/// @return whether WindowServer accepted the surface. When the connector's presentFlags (see
///         WXFCardGetScanout) has bit 2 clear WindowServer reports success whatever the display did,
///         so a true here does not mean the frame is on screen. The surface should be made the way
///         WindowServer makes its own: "IsDisplayable" true and "IOSurfaceCacheMode" 0x700.
bool WXFCardPresent(WXFConnectorID connector, IOSurfaceRef surface, bool vsync);

/// What WindowServer is scanning out on a connector right now.
typedef struct {
    uint32_t width, height;       ///< Pixels of the displayed surface.
    uint32_t pixelFormat;         ///< IOSurfaceGetPixelFormat of it, a FourCC ('BGRA', 'RGhA', 'l10r', ...).
    uint32_t framebufferFormat;   ///< -[CAWindowServerDisplay framebufferFormat], QuartzCore's own code.
    /// SLCADisplay+2300. Bit 2 (4) set means WXFCardPresent copies into the display's surface with
    /// the Metal compositor (and then needs updates enabled); clear means QuartzCore swaps in the
    /// surface as given.
    uint32_t presentFlags;
} WXFScanoutInfo;

/// The connector's displayed surface (-[CAWindowServerDisplay displayedSurface]) described, which is
/// the size and format a surface for WXFCardPresent should have. False if there is none (the
/// connector is unknown, blanked, or WindowServer has not drawn to it yet).
bool WXFCardGetScanout(WXFConnectorID connector, WXFScanoutInfo *out);

/// -[CAWindowServerDisplay setDisablesUpdates:]. While it is set, QuartzCore refuses every update
/// to the connector (CA::WindowServer::Server::can_update fails), so WindowServer stops drawing it
/// and whatever was last presented stays on screen. It also makes WXFCardPresent do nothing when
/// presentFlags has bit 2 set: to show a frame on such a connector turn it off for the present and
/// back on straight after (WXFCardPresentExclusive does exactly that).
bool WXFCardSetUpdatesDisabled(WXFConnectorID connector, bool disabled);
bool WXFCardGetUpdatesDisabled(WXFConnectorID connector, bool *disabled);

/// WXFCardPresent for a connector whose updates are disabled: enables them just for the present
/// and disables them again afterwards, so WindowServer's own drawing is kept off. Same rules as
/// WXFCardPresent. Main thread only.
bool WXFCardPresentExclusive(WXFConnectorID connector, IOSurfaceRef surface, bool vsync);

/// The last vblank and the interval between them, in mach absolute time units
/// (-[CAWindowServerDisplay previousVBL] and vblDelta). Either may be 0 before the first vblank.
bool WXFCardGetVBlank(WXFConnectorID connector, uint64_t *previous, uint64_t *interval);

#ifdef __cplusplus
}
#endif

#endif
