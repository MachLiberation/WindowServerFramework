# Display bring-up internals (the "card0" notes)

How WindowServer discovers, configures and drives displays, read from the macOS build whose
`dyld_shared_cache_arm64e.i64` is at `/Users/bedtime/Downloads/`. Every address below is in that
IDB. Names are raw Mach-O names (what `WXFResolveServerSymbol` takes, minus the leading
underscore IDA shows twice).

Status of each claim: **read** = decompiled and followed; **inferred** = follows from names or a
caller but the body was not read; **open** = not looked at yet.

## The layers

```
IOKit (IOMobileFramebuffer / AppleDisplay)            hardware
  CA::WindowServer::{AppleInternal,AppleExternal,AppleDFR}Display   QuartzCore backends
    CAWindowServerDisplay  (one per connector, ObjC)                 QuartzCore  <- "drm connector"
      WS::Displays::SLCADisplay  (C++, vtable Display)               SkyLight    <- WS's view of it
        WS::Displays::CAWSManager  (singleton, CAManager())          SkyLight    <- "drm card"
          configuration_engine  (modeset)                            SkyLight    <- "drm atomic commit"
```

### Discovery: `-[CAWindowServer _detectDisplays]` (0x18b2fc654) — read

Loops three backends. The tables are `count_funcs` (0x1e894e028) and `open_funcs` (0x1e894e048):

| i | count | open |
| - | ----- | ---- |
| 0 | `CA::WindowServer::AppleInternalDisplay::count` | `…::open(unsigned long)` |
| 1 | `CA::WindowServer::AppleExternalDisplay::count` | `…::open` |
| 2 | `CA::WindowServer::AppleDFRDisplay::count` | `…::open` |

For each index `open` returns a `CA::WindowServer::Display*`; vtable slot +1792 turns it into a
`CA::WindowServer::Server*` (null → the display is dropped through vtable +8). A non-null server
becomes `-[[CAWindowServerDisplay alloc] _initWithCADisplayServer:]` and is added with
`-[CAWindowServer addDisplay:]`. The first display also registers CA render observers 34/35
(vsync-off support). **Every connector WindowServer ever has is a `CAWindowServerDisplay`.**

`CAWindowServerDisplay.displayType` (0x18b2fe220) is bits 10..12 of `Display+704` when that is
1…4, else 0. Meaning of the values, from `CAWSManager::initialize`: 0 = internal panel,
1 = external, 3 = virtual (`CAVirtualDisplay::make_display` tests `== 3`), 4 = DFR/Touch Bar
(goes into the second `DisplaySet` at manager +344, not the hardware one). 2 is not seen on any
path read.

### Wrapping: `CAWSManager::initialize` (0x1874bfba0) — read

Logs `[ Display:Config ] Initializing hardware displays.`, then walks `[_g_server displays]`.
Per display (types 0/1/4 only; `SkipInternalDisplays`, `SkipExternalDisplays`, `Dullahan` prefs
turn them off with `setEnabled:0` instead):

1. `setDisablesUpdates:0`, `setAccessibilityColorMatrix:scale:`, `setInvertsColors:0`.
2. `operator new(3424)` — a `make_shared` block: control block at +0, **the `SLCADisplay` object
   at block+32**. Block offsets below are object offsets (block − 32).
3. `SLCADisplay::SLCADisplay()`, then `obj+784 = [ca_display copy]` (the `CAWindowServerDisplay`),
   `obj+2352 = displayType`, `obj+876/880/884/888 = index, index, 1<<index, index`,
   `obj+808 = [ca_display displayId]`, class flags in `obj+2296` (bit2 internal, bit3 DFR,
   bit4 external, bit34 virtual).
4. Installs blocks on the CA display:
   `setHotPlugCallback:` (block_invoke 0x18749c8fc), `setDisplayStateChangedCallback:`
   (0x18749ce80, calls `[ca update]`), `setBrightnessCallback:`, `setUpdateRequestCallback:`,
   `setSecureIndicatorBrightnessCallback:`.
5. `SLCADisplay::process_display_connect(obj, 0)` (0x187497038) — if it fails or the display has
   no `uniqueId`, `process_display_disconnect(obj, 0, true)`.
6. `DisplaySet::add_display(manager+56, {obj, ctrl})` (or manager+344 for DFR) and push onto the
   `os_unfair_lock`ed (+1384) hardware vector at +1392.

Then `XPCServiceClient::broadcastXPCNotification(2)` and `(4)`, the HID display listener
(`WSHIDDisplayEventListener`, queue `com.apple.SkyLight.display.events`), and a block on the
manager queue (+8) that finishes initialisation. `CAManager()` (0x1874b2454) constructs the
singleton (1744 bytes) on first call; the vptr is checked against `derived_class_vptr`.

### Connect: `SLCADisplay::process_display_connect(reason)` (0x187497038) — partly read

Asserts `_ca_server_display != nil`. Rebuilds the mode list (`reevaluate_modes`, then
`set_initial_mode(true)`), re-finds the `CADisplay` whose `displayId` matches
(`+[CADisplay displays]`, KVO on `availableModes`), calls `[ca update]`, and fails with
`Display %x failed to return any CA modes` when `availableModes` is empty. Then reads panel
size, `externalDisplayAttributes` (manufacturerID, productID, serial, year/week), loads
override plists from `/Library/Displays/Contents/Resources/Overrides` and the system and
AppleInternal equivalents, applies overscan. Returns bool.

### Hotplug — read

* The CA display's hotplug block calls
  `WS::Displays::reconfigure_callback_process_hotplug_event(displayId, state, 1)` (0x18749cb60)
  directly, or after `defer_hotplug_seconds` (a cgdebug float) via `dispatch_after`.
  `state` 1 = connect, 0 = disconnect.
* That function takes `deferred_hot_plugs_lock()`, coalesces into a `std::map<int, hot_plug_element*>`
  at manager +1496 (40-byte elements: +0 mach time, +8 displayId, +12 state, +16 reason, +24/+32
  connect/disconnect counters), and calls `process_deferred_hotplug_events()` (0x1874b77e8),
  which dispatches a block (0x1874b7d10) that does the real work, with
  `process_deferred_hotplug_unplug` (0x1874b78f8) for disconnects.
* `CAWSManager::process_hotplug_event(displayId, state, reason, bool)` (0x1874b79b0) finds the
  display with `Manager::hardware_display_by_id` (`__ZNK2WS8Displays7Manager22hardware_display_by_idEi`,
  0x1873b7628), logs `[ Display:Hotplug ] Processing hotplug "in"/"out"`, then
  `process_display_connect(reason)` / `process_display_disconnect(reason, flag)`.
  Reason strings (table `off_1E079F298`, index `reason-1`): 1 `CA`, 2 `PM`, 3 `SP`, 4 `API`.
* **`CAWSManager::inject_hotplug(bool state, int displayId, unsigned reason)` (0x1874c31ac)** —
  checks the display exists and `is_dfr()` (vtable +448) is false, then
  calls `reconfigure_callback_process_hotplug_event`. It is what the client-API softplug uses
  (`config_command_softplug::apply`, 0x1873d59e0, enqueues it on the main thread with reason 4)
  and `set_debug_options`.

### Modes — read

* `SLCADisplay::modes()` (0x187491974) copies one of two `vector<Mode>`s, chosen by vtable +528
  (`is_in_mirror_set`). The normal list is at `obj+1880` (begin) / `+1888` (end), the mirroring
  list at `obj+1904`. `default_mode()` (0x18749b624) returns the first mode whose dword at `+124`
  has bit 2 set (and falls back to the first).
* `WS::Displays::Mode` is **184 bytes**, read from its constructor (0x1872f1234):
  `+0` u32 id · `+4/+8` u32 pixel width/height · `+12/+16` copies of them · `+20` float scale ·
  `+24/+28` u32 point width/height (pixels ÷ scale, rounded) · `+48/+52` floats · `+56` float
  refresh rate · `+60` float (≤ refresh) · `+64` `vector<CADisplayMode*>` · `+88` `CADisplayMode*`
  (what `[ca setCurrentMode:]` is given) · `+96/+104` link description · `+120` u32 · `+124` u32
  flags (bit 2 default) · `+136…` colour/depth words.
* The current mode is copied to `obj+1928` (so `+1928` is its id, `+1932` width, `+1936` height,
  `+1984` refresh).
* `SLCADisplay::set_current_mode(Mode, bool)` (0x18749b100) validates the mode against the link
  modes (`find_link_mode_match`), stores it, recomputes the geometry and surfaces, and does
  `[ca_display setCurrentMode:(Mode+88)]` (polling `update` up to 20×0.5 s when the display
  requires it). Failure logs `Unrecognized mode set attempted: %s`.
* Callers of `set_current_mode`: `set_initial_mode`, `process_display_disconnect`,
  `configuration_engine::reconfigure_displays`, `select_display_set`, calibration, and
  `CAVirtualDisplay::make_display`.

### Configuration (modeset) — read

`configuration_engine` lives at **`CAWSManager`+952**. A transaction is
`begin(from, to, persistence)` → `apply_command(cmd)` × n → `commit(bool immediate)`.
Commands (`config_command_*`, each with `apply`): `mode`, `output_mode`, `origin`, `rotation`,
`mirror`, `unmirror`, `independent_output`, `softplug`. `commit` unmirrors where needed,
`config_set::sanitize`s, diffs with `determine_change_summary_for_config_sets`, logs
`No change between prior and requested configuration.` when equal, otherwise runs
`reconfigure_displays()` now or from `gIdleQueue`. The public entry for clients is
`CAWSManager::mig_complete_configuration` (0x1874c7b88) →
`configuration_engine::config_via_client_api(a1+952, token, CGSDisplayConfig*, size, bool*)`;
it requires the console session (`session+93 == 1`) and returns 1007/1004/1010/1001 on bad
input / locked display / not console / bad port.
`config_command_mode::apply` (0x1873d3534) looks up the mode **id** in the config entry's mode
list (616-byte `config_set_entry`, mode vector at +48, mirror modes at +72) and asserts on a missing
id on internal builds, so a mode id must come from the display's own list.

**Single-call modeset: `configuration_engine::config_current_mode(engine, int displayId,
unsigned modeId, bool)`** (`__ZN2WS8Displays20configuration_engine19config_current_modeEijb`,
0x1873e33b4; the `bool` is not read by the decompile). It builds a session config set
(`CAWSManager::session_config_set(set, engine+104)`), `begin(…, 2)`, `config_command_mode::make_command(
&cmd, engine+24, displayId, modeId)` (0x1873d2f94: finds the 616-byte entry whose display id at +40
equals `displayId`; returns null if none), `apply_command(cmd, 0)`, `commit(1)` (the `1` runs
`reconfigure_displays()` immediately). The only WindowServer caller is
`CAWSManager::virtualDisplayApplyWithDictionary`, which passes a mode index into the display's
mode list (for virtual displays id == index; for hardware use `Mode.id`, which is what
`apply` compares). `begin` asserts `!_config_open` (engine+116 bit 0), so `WXFCardSetMode` checks that
flag first. `commit` calls `save_current_configuration` on the no-change path, and persistence
option 2 is passed, so assume the chosen mode is remembered across restarts: restore the old one.

### Presenting frames — read

`-[CAWindowServerDisplay presentSurface:withOptions:]` (0x18b307270) calls vtable +80 on the
`CA::WindowServer::Server`. WindowServer's own wrapper is `SLCADisplay::present_iosurface(IOSurface*,
bool vsync)` (0x1874a4d3c): it requires `[ca enabled]` and a `uniqueId`; if `obj+2300 & 4` is
clear (HMD/direct scan-out) it hands the surface straight to `presentSurface:` and records it
with `set_swapped_iosurface`; otherwise it asserts the surface size equals the display's surface
bounds, opens a `CARenderUpdateBegin2`, gets `currentSurfaceWithOptions:…`, blits with
`CompositorMetal::CopyTextureToTextureWithRegion`, flushes and finishes the external update.
`register_transaction_complete_callback` installs `setFrameInfoCallback:` (the page-flip event);
the manager's completion handler (0x1874bcf30) looks the display up in an
`iosurface_ready_callback_map` (`register_for_iosurface_ready`, 0x1874bcb34).

**Taking a display over.** `-[CAWindowServerDisplay setDisablesUpdates:]` (0x18b303cbc) sets
bit `0x800` of the `CA::WindowServer::Display` dword at **+944** (`Server+88`); `disablesUpdates`
reads it. `IOMFBDisplay::can_update` (0x18b37d01c) returns 251 when `*(display+945) & 8`, which is that
bit, so `Server::can_update` (0x18b0ecd68, `vtable+392 == 0`) and `-[CAWindowServerDisplay
canUpdateWithFlags:]` turn false: QuartzCore stops drawing the display and its last frame stays up.
Consequence for `present_iosurface`: the `obj+2300 & 4` path (Metal copy) tests `canUpdateWithFlags:0`
and returns 0 while updates are disabled. The other path (`presentSurface:withOptions:`) was not read
past the Server vtable call (+80), so whether it honours the bit is unknown. `WXFCardPresentExclusive`
therefore clears the bit for the present and sets it again right after. `displayedSurface` (Server
vtable +72) is the current scanout IOSurface; `framebufferFormat` is Display vtable +256.
`refresh_timing(prev, delta)` (0x1874a0d14) = `[ca previousVBL]`, `[ca vblDelta]` (fallback 1/max(30, rate)).

### Virtual connectors — read

`CAWSManager::virtualDisplayCreate(uint,uint,uint,CGSize,CFDictionary*)` (0x1874b93fc) is what
`CGVirtualDisplay` ends up in. It requires the entitlement `com.apple.private.SkyLight.virtualdisplay`
(`caller_has_entitlement`), refuses off-console sessions, builds an `SLVirtualDisplayConfiguration`
(`configurationWithDictionaryRepresentation:` / `…WithDisplayInfo:`), rejects duplicate
vendor/product/serial, and calls `CAVirtualDisplay::make_display(modes, count, w, h, …)`
(0x18749d92c). That creates a `CAWindowServerVirtualDisplay` from the options
`kCAVirtualDisplayWidth/Height` (required), `UpdateRate`, `MinimumFrameDuration`, `PixelFormat`,
`PixelFormatFollowsMode`, `Name`, `PhysicalWidth/Height`; `addDisplay:`s it to `_g_server`; hooks it to
the matching `CADisplay`; and sets the flags. `-[CAWindowServerVirtualDisplay initWithOptions:]`
(0x18b309eac) builds a `CA::WindowServer::VirtualDisplay::open(...)` (name `Virtual-%d`), a
`CA::WindowServer::Display` (`calloc` 0x6548 bytes) and `Server`. `virtualDisplayDestroy(uint)` is at
0x1874bbc24.

### Power

`SLCADisplay::set_power_state(bool)` only flips bit 22 of `obj+2296` (and only if the CA display has a
`uniqueId`). The real power path is `CAWSManager::update_displays_logical_power_state`,
`send_power_state_notification`, `-[CAWindowServerDisplay setBlanked:]`, `setEnabled:`
(→ `CA::WindowServer::Server::set_display_state`). **open** — bodies not read.

## What a tweak can call without hooking anything

All of this is in-process once the tweak is inside WindowServer:

* ObjC, QuartzCore: `[CAWindowServer serverIfRunning]`, `-displays`, `addDisplay:`/`removeDisplay:`,
  and the whole `CAWindowServerDisplay` method list (`name`, `displayId`, `displayType`, `uniqueId`,
  `bounds`, `nativeSize`, `panelPhysicalSize`, `enabled`/`setEnabled:`, `isBlanked`/`setBlanked:`,
  `presentSurface:withOptions:`, `setHotPlugCallback:`, `setFrameInfoCallback:`, `previousVBL`,
  `vblDelta`, `setOrientation:`, …). `CAWindowServerVirtualDisplay initWithOptions:` creates a
  connector with no SkyLight wrapper.
* C++, SkyLight, by raw name: `__ZN2WS8Displays9CAManagerEv`, `…CAWSManager14inject_hotplugEbij`,
  `…CAWSManager20virtualDisplayCreate…`, `…CAWSManager21process_hotplug_eventEi33…`,
  `__ZNK2WS8Displays7Manager22hardware_display_by_idEi`.

## WXFCard (the API built on this)

`WindowServerFramework/api/include/WXFCard.h`, `api/WXFCard.m`, example `CardExample`. Names:
`WXFCard*` for the card, `WXFConnector*` for displays (`WXFDisplay*` already means a PKG display in
`WXFMisc.h`).

| Call | Maps to | Evidence |
| ---- | ------- | -------- |
| `WXFCardCopyConnectors/GetConnector` | `-[CAWindowServer serverIfRunning].displays`, the `CAWindowServerDisplay` getters | read |
| `connector.managed/modeCount/currentModeID`, `WXFCardCopyModes` | manager+1384 lock, +1392 `vector<shared_ptr<Display>>`, `SLCADisplay+808` id, `+1880/+1888` `vector<Mode>`, `+1928` current mode | read, offsets only for this build |
| `WXFCardAddHotplugObserver` | hook on `CAWSManager::process_hotplug_event` (group `WXFHookGroupCardHotplug`) | read |
| `WXFCardSetConnected` | `CAWSManager::inject_hotplug(mgr, state, id, 4)` on the main thread (what `config_command_softplug` does) | read |
| `WXFCardSetBlanked/SetEnabled` | `-[CAWindowServerDisplay setBlanked:/setEnabled:]` | read the ObjC side only; the SkyLight power path is open |
| `WXFCardPresent` | `SLCADisplay::present_iosurface(display, surface, vsync)` | read; effect while WS composites is unknown |
| `WXFCardSetMode` | `configuration_engine::config_current_mode(mgr+952, id, mode, false)` on the main thread, guarded by the `_config_open` flag (engine+116) | read; untested live |
| `WXFCardSetUpdatesDisabled/Get…` | `-[CAWindowServerDisplay setDisablesUpdates:]`, `disablesUpdates` | read; untested live |
| `WXFCardGetScanout` | `displayedSurface` size/format, `framebufferFormat`, `SLCADisplay+2300` | read; untested live |
| `WXFCardPresentExclusive` | clears the disable bit around `WXFCardPresent` | read; untested live |
| `WXFCardGetVBlank` | `previousVBL`, `vblDelta` | read |

The manager is read from the function-local static behind `CAManager()`
(`__ZZN2WS8Displays9CAManagerEvE7manager`), never created by calling `CAManager()`.

Not built: replacing the `_detectDisplays` backends, and virtual connectors.

**Status: live-verified for reading (2026-10-28, `CardExample` after a WindowServer restart).** The
card came up 5 s after load with 3 connectors: `1 internal 'LCD'` (enabled, managed, native
3024x1964, `bounds` 3600x2338 pt, 132 modes, vblank interval 199999 ticks = 120 Hz at the 24 MHz
timebase; the offsets for the mode list, ids, width/height/scale/refresh and the default flag
(3024x1964@120, id 54) all gave sane values), and two empty `external` slots (`External`,
`External-1`: disabled, blanked, no unique id, one placeholder 1x1 mode, current). The hotplug hook
installed (no event happened). **Not run live:** `WXFCardSetConnected`, `SetBlanked/SetEnabled`,
`Present`. `CardExample` only logs (`WXF card0` lines): connectors, modes, hotplug.

## CubeExample

`CubeExample/` (`Tweak.m`, `CubeExample.metal`; the metallib is linked into the dylib as
`__DATA,__wxf_shader`, like `DragShaderExample`). Nothing happens at load. A change to
`/private/tmp/wxf-cube` starts it: `connector=<id> mode=<id> seconds=<n>` (all optional;
connector defaults to the internal one) or `stop`. It optionally runs `WXFCardSetMode`, waits for
`currentModeID` to change, reads `WXFCardGetScanout`, makes three IOSurfaces of that size and pixel
format (BGRA, RGhA and l10r are mapped), disables the connector's updates and presents a Metal-rendered
cube at 60 Hz with `WXFCardPresentExclusive(…, vsync=false)`. At the end (default 15 s, max 120) or after
45 failed presents it re-enables updates and puts the old mode back. Logs: `WXF cube: …` lines.

**Live run (2026-10-28, 10 s, no modeset, internal display):** scanout 3600x2338, pixel format
`0x26623338` ('&b38', not one of the mapped formats, so BGRA surfaces were used), framebufferFormat
643969848, `presentFlags` 0x800030e1 (bit 2 clear: the `presentSurface:withOptions:` path, not the Metal
copy). 575 frames in 10 s, every present returned true, updates re-enabled at the end. **The display
froze and showed nothing:** the cube's surfaces were plain IOSurfaces. On this path
(`IOMFBDisplay::present_surface`, 0x18b381ef4) the surface goes to `IOMobileFramebufferSwapBegin`
→ `fb_swap_set_layer(layer 0)` → `swap_end`; `SLCADisplay::present_iosurface` returns 1 on this path
no matter what, so the logged `presented=1` meant nothing. WindowServer's watchdog logged `display 1
regained readiness after 10.0s (2392 failures)` and the cursor `failed set_cursor_surface`. WindowServer's
own scanout surfaces (`WSIOSurfaceCreateWithFormatDisplayable`, 0x187487fcc) are created with
`IsDisplayable` = true and `IOSurfaceCacheMode` = 1792 (0x700), which the cube now does too (the
cache mode hint came from the user). Modeset has not been run live.

**Pacing results (same day):** with a free-running 60 Hz timer the user saw lag spikes (the beat of a
17.3 ms timer against 8.33 ms vblanks, unmeasured). Starting each frame 2.5 ms before a vblank
(`previousVBL`/`vblDelta` mach ticks, offset-corrected to `WXFCurrentTime`) gave 600/600 frames
vblank-paced, but at 2 vblanks per frame (16.67 ms, 60 fps; why not 1 is unknown), max interval 33.4 ms,
render+`waitUntilCompleted` up to 29 ms, present at most 1.9 ms. Presenting the previous frame without
waiting for the GPU **hung WindowServer's main thread on the third present** and had to be killed:
do not do that; the cause was not found (no sample of the hung process).

## XFCEExample

An X server on a connector. `XFCEExample/xfce-session.sh start` (as you, not in WindowServer) runs Xvfb
with `-fbdir /private/tmp/wxf-x11`, a session D-Bus, twm (MacPorts has no xfwm4 here; its twmrc
turns off interactive placement, which holds an X server grab and hung every X query), xfce4-panel,
thunar and xterm. Xvfb can't make `/tmp/.X11-unix` without root, so it listens on loopback TCP 6007
(`DISPLAY=localhost:7`) behind a cookie in `Xauthority`. The screen is `Xvfb_screen0`, an XWD file: 160-byte
big-endian header, `ncolors` x 12 bytes of colour map, then BGRX rows (`bytes_per_line` stride). Checked
live: the panel, Thunar and an XTEST click on the panel's menu all render into that file.

The tweak (`Tweak.m`, trigger `/private/tmp/wxf-xfce`, `seconds=N`, `stop`, or Control+Option+Command+Escape)
maps the file, uploads it to a Metal texture every frame, draws it scaled and centred with an arrow
for the pointer (X doesn't draw one into its screen) onto displayable IOSurfaces (see the cache mode
note above), and shows them with the cube's takeover and vblank pacing, waiting for each frame's GPU
work. Input: `WXFEventAddHandler` consumes every key, mouse and scroll event while it runs and writes
`m X Y`, `b N 1|0`, `k MACVK 1|0` lines to the FIFO `/private/tmp/wxf-x11/input`; `wxf-xinput`
(built by the script) replays them with XTEST. Modifier keys are derived from flag changes. Scroll
direction on the horizontal axis and the macOS to X key table are unchecked.

**First live run (2026-10-28):** XFCE showed on the internal display, 3600 frames in 60 s, vblank-paced
at 16.67 ms (max interval 66 ms, max render+wait 30 ms). Two bugs: (1) the pointer reached only half
the screen: `CAWindowServerDisplay bounds` is in pixels (3600x2338) but event locations are points
(mode 66 is 1800x1169 pt at 2x), so the pointer is now scaled by the current mode's point size; (2) a click
froze the X server (not WindowServer: the tweak ended on time). Cause, reproduced headless by sending
the same FIFO events: with a twmrc that had no bindings, pressing a twm titlebar froze Xvfb for every new
client (`kill -9 twm` released it; Xvfb itself was idle in `poll`, so it was a client grab, and SIGTERM
didn't kill the stuck twm). Fixed with `Button1 = : title : f.move`, `: frame : f.resize`, `: root : f.nop`.

**Second round:** typing and the XFCE session worked live; the user could not reproduce the X-server
freeze again (the input logging stays in). Complaints: tearing and two cursors. The second cursor is
macOS's own, still on screen next to the tweak's arrow, so the arrow is now off by default
(`pointer=1` turns it on). Tearing: the X server paints into the file while it is read, so the frame is
now copied, re-read and compared (up to 3 tries) and the run logs how many frames changed during the copy;
IOMFB's swap itself is hardware-synchronised, so a torn picture was assumed to come from the content. The surface ring is
4 deep. Not yet checked live.

**Wallpaper and picom (2026-10-28).** Both are optional and read from the user's own `~/.config`, not
the repo: `~/.config/wxf-xfce/wallpaper.*` is painted on the root window by `XFCEExample/wxf-wallpaper.m`
(ImageIO decode, `XPutImage` into a root pixmap, `_XROOTPMAP_ID`), and `~/.config/picom/picom.conf` is passed to
picom if it is installed. picom v13 (yshui/picom 244c795) builds on macOS with MacPorts' xcb libs, libev, and
Homebrew's libconfig + uthash (`meson setup build --prefix ~/.local -Dopengl=false -Ddbus=false -Dwith_docs=false`;
`PKG_CONFIG_PATH` and `-I/-L` for /opt/local and /opt/homebrew). Xvfb here has Composite, DAMAGE, RENDER and
XFIXES but no usable GL, so the xrender backend is the one to use. Stock xrender fails at start
("Failed to create SHM segment") because it uploads images through `xcb_shm_create_segment`, i.e. MIT-SHM
fd passing, which XQuartz's Xvfb does not do. `docs/picom-xrender-putimage.patch` replaces that with
`xcb_put_image`; with it, picom runs and draws shadows and fades. Start picom before the programs: windows
that were already mapped when picom started (or when it was restarted) came up blank until redrawn.
**picom `fading = true` makes windows vanish on hover** (live report, reproduced headless): when the pointer
enters a window twm moves focus, picom starts an opacity fade, and the fade stalls partway, leaving the window
blank (shadow only) or half transparent until something else repaints. With `fading = false` the same hover sweep
leaves every window intact; `inactive-opacity` alone is fine. Cause of the stall not traced further.
Not a bug but looked like one: Thunar (mapped later, RandomPlacement) can sit on top of xterm.

**Cocoa bridge (2026-10-28).** XFCEExample's tweak is one dylib loaded into WindowServer *and* into the apps
its whitelist names (`WXFGetHost()` in `LoadFunction`, as TaskbarExample does). In an app started by
`XFCEExample/xfce-open.sh` (which sets `WXF_XBRIDGE=1`) the non-WindowServer branch `dlopen`s
`<tweaks>/XFCEExample.support/libXFCEBridge.dylib` (the XFCEBridge Xcode target, installed by `deploy.sh`) and
calls `XBridgeStart`. The bridge is a separate dylib because it links AppKit, which must not load into
WindowServer; it is also loadable with `DYLD_INSERT_LIBRARIES` (`xfce-open.sh --inject`) for apps outside
the whitelist. Modeled on `~/Developer/ceraina/bridge` (AppKit apps as Wayland clients); here the other end is
the X server.

* `XBX11.m` is a hand-written X11 client (no libX11: XQuartz's libraries have no arm64e slice and the apps are
  arm64e). Loopback TCP to `localhost:7` with the cookie from `/private/tmp/wxf-x11/Xauthority`
  (`WXF_X_DISPLAY` / `WXF_X_AUTHORITY` override; **not** `$DISPLAY`, which on the Mac names XQuartz's own server).
  Requests used: CreateWindow, ConfigureWindow, MapWindow, DestroyWindow, ChangeProperty (WM_NAME as Latin-1,
  _NET_WM_NAME, WM_CLASS, WM_PROTOCOLS = WM_DELETE_WINDOW, WM_NORMAL_HINTS min/max, _NET_WM_PID), CreateGC,
  PutImage, InternAtom. PutImage is split under 262140 bytes per request (no BIG-REQUESTS). A first version
  typed `Pad4` as `uint16_t`, which wrapped for payloads over 64 KB and overran the request buffer
  (SIGBUS in `Send`).
* Each visible NSWindow gets an X window (`orderWindow:relativeTo:`, `orderFront:`, `makeKeyAndOrderFront:`,
  `orderFrontRegardless`, `orderOut:`, `close` swizzled, plus a scan of `NSApp.windows` every half second
  because Terminal's restored window arrived by a route the hooks missed). The NSWindow itself is moved
  behind the desktop picture (`kCGDesktopWindowLevel - 1`), made click-through and shadowless, traffic lights
  hidden: still drawn and captured, never seen on the Mac.
* Pixels: `SLSHWCaptureWindowListToIOSurfaceProxied` (ceraina's call and options: nominal resolution, ignore
  global clip, allow non-intersecting), BGRA premultiplied, box-filtered 2x to one pixel per point (the X
  screen is 1x), the AppKit title bar cropped when twm supplies one (not for toolbar or full-size-content
  windows), diffed against the previous frame, only the changed row band sent. 30 Hz while changing, one
  tick in eight after 1.5 s idle. Falls back to `displayRectIgnoringOpacity:`. Alpha is dropped (X windows are depth 24).
* Input: X keycode - 8 is the evdev code, mapped to a Mac virtual key code with ceraina's table plus the editing
  keys; characters come from `UCKeyTranslate`, function keys get their `NS*FunctionKey` characters. Modifier bits:
  Shift, Lock, Control, Mod1 (Alt) = Option, Mod4 (Super, which the tweak sends for Command) = Command.
  **Mouse and key events are posted with `-[NSApp postEvent:atStart:NO]`, not `sendEvent:`**: Terminal's
  text view tracks the mouse in a nested event loop inside mouse-down, and the rest of the gesture has to be
  read from the X socket then; a dispatch source cannot run again while its own handler is on the stack, so
  with `sendEvent:` the ButtonRelease and every later event were never read. `NSView -acceptsFirstMouse:` is
  patched to YES (the app is never active). Scroll: the NSEvent made from a CGEvent has no window (its location
  is a screen position and the window is hidden), so the bridge hit-tests the view itself and calls
  `-scrollWheel:` on it. Close: `WM_DELETE_WINDOW` -> `performClose:`; twm has no close button, so
  `Button3 = : title : f.delete` is in the generated twmrc. Resize: ConfigureNotify with a new size resizes the
  NSWindow (the X window follows the app if it refuses).
* **Sandboxed apps can't connect**: TextEdit's connect to 127.0.0.1:6007 fails with EPERM. Terminal (not
  sandboxed) works; deploy.sh whitelists Terminal, Activity Monitor, Console, Disk Utility, Font Book,
  Automator, Script Editor and Keychain Access. A way in for sandboxed apps (a sandbox extension issued
  from WindowServer, or a mach-port relay) is not built.
* Verified headless (XTEST into the X server, framebuffer screenshots): Terminal appeared with its contents,
  typing, click, scroll, resize (title bar showed the new row count) and right-click-title close all worked,
  through both `DYLD_INSERT_LIBRARIES` and the Ammonia path. Not seen on the display. Not handled: menus and
  popovers (popup-level NSWindows are left native, so invisible), the app's menu bar, drag and drop, input
  methods, transient/sheet parenting, windows whose alpha matters (rounded corners show black).

## Open

* Vtable slots known so far (`SLCADisplay`, vtable 0x1e873ff38, slot = symbol+16+offset):
  +40 `display_id` (returns `obj+808`), +424 `is_builtin`, +448 `is_dfr`, +520 `is_hmd`, +528
  `is_in_mirror_set`, +544 `is_mirror_slave`, +568 `is_potentially_active`, +1360 `compositor`.
* `AppleInternalDisplay::open` / IOMFB: how the IOKit service is matched (needed to fake a
  hardware connector).
* `Mode` words from `+136` on.
* `CAWindowServerDisplay` mode methods (`currentMode`, `setCurrentMode:`, `availableModes` are
  not in the symbol table under those exact names — they are probably on the `CADisplay` class).
* Power path.
