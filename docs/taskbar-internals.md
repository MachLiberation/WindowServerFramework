# Taskbar internals

What `TaskbarExample` (a 50 point bar replacing the menu bar and the Dock) rests on, in WindowServer
and in MenuBarAgent. The WindowServer facts were read from SkyLight in the dyld shared cache
(`~/Downloads/dyld_shared_cache_arm64e.i64`, macOS 27); the MenuBarAgent facts from the running
agent (probe tweak, windows/views/ivars) and its binary. Items marked **unverified** have not been
seen working: the WindowServer half needs a WindowServer restart (a logout) to try.

## Two processes, one tweak

Ammonia loads a tweak into every process its `.whitelist` names. `deploy.sh` writes `WindowServer`
and `MenuBarAgent` for `TaskbarExample`. `WXFGetHost()` says which one the code is in, and
`SetupFramework` only installs the WindowServer hooks in WindowServer. `killall MenuBarAgent`
restarts the agent with the tweak and does not log out; WindowServer needs `sudo killall WindowServer`.

## WindowServer: always visible, 50 points, work area

| What | Where | Status |
| --- | --- | --- |
| Bar rectangle height | `menu_bar_bounds_for_space` (see menubar-internals.md) | verified earlier |
| Work area on a notched display | `WS::Displays::Display::evaluate_display_parts`: notch rects at `+312 +360 +392 +424 +472`, menu bar height `+504`. `WXFMenuBarHook_EvalParts` rewrites them after the original runs | **unverified** |
| Never hidden | `managed_menu_space_synchronized_set_menu_bar_reveal(space, reveal, flag)`: every reveal of every space ends here (1.0 shown). `WXFMenuBarHook_Reveal` raises any smaller value to 1.0 | **unverified** |
| Dock takes no space | `_XSetDockRectWithReason` stores the rectangle (4 doubles at `+64` of the session package data, `*(*(__sessionControlRef+32)+216)`), `_XGetDockRectWithReason` replies with it (4 floats at `+36`). `WXFDockHook_*` zero both | **unverified** |

AppKit's `NSScreen.visibleFrame` is the layout frame (display minus the bar, and on a notched display
the notch inset) minus the Dock rect unless the Dock is hidden. Probed in the agent: `layoutFrame`,
`_notchFrame`, `_dockRect`, `_dockHidden`.

## MenuBarAgent: what the bar is

- A sandboxed AppKit/Swift process. The bar is `MenuBarCore.DisplayItemAppKitWindow` windows at
  level 24, one per app whose menus it has loaded (same frame, only the front app's is shown), plus
  the status item windows. Their content view is `MenuBarHitTestingView`; its direct subviews are
  `AppMenuItemContainerView`, one `AppMenuItemView` per menu title of the app (Apple menu,
  app name, File, ...) and one `SceneHostDisplayItemContainerView` per status item (scene hosted,
  so the tray is the real one).
- `AppMenuItemView`: `_title` is a Swift `String` at `+576`, `_prefersBoldFont` at `+592` (the app
  name), `remoteProcessIdentifier` at `+648` (int32, the app's pid). Class names: use
  `NSStringFromClass([view class])`; `class_getName` is mangled and `object_getClass` is an
  `NSKVONotifying_` subclass.
- Accessibility is blocked in the agent (`AXUIElementCopyAttributeValue` returns -25204), and
  `accessibilityPerformPress` on an item returns NO. `NSWorkspace` works.
- **A synthetic click opens the real dropdown.** `[window sendEvent:]` with an `NSEvent` mouse down
  and up in the item's window coordinates opens the app's own menu (confirmed: iTerm's Edit menu, a
  layer 101 window). A `CGEventPost` is not needed and the agent is not AX trusted.
- **Where the dropdown opens is not in the views.** It opened at the item's original place when the
  item view was moved (waiting 600 ms first), when the bar window was moved 500 points, and with
  `leadingItemSpacing` (`MenuBarHitTestingView +568`, 20) changed. AppKit in the app gets the
  title rectangles from the agent (`+[NSMenu(MenuBarAgent) _didUpdateTitleRects:]`, a dictionary of
  item id to rect) and positions the dropdown from them; the agent builds them from its own layout
  model. `SLSMoveWindow` on the dropdown from the agent fails with 1000 (not the owner).

## The taskbar

Two panels per display in the agent. The status items are not drawn in the agent's bar windows
(`DisplayItemAppKitWindow`, offscreen in `CGWindowListCopyWindowInfo`): WindowServer's own `Menubar`
window (owner Window Server, level 24, onscreen) draws them together with the system's blue backing
in one window, so nothing can be put between the two. Observed: a base panel at level 23 or 24 under it
never shows, and the items stay on blue.

So the cover (level 25) is the whole bar width and hides all of it. It draws the running apps on the left
and, at the right, the tray:

- `TBTrayBarView`: the pinned status items (`kPinned = 1`, the clock) as `CALayerHost` clones of each
  item's scene context id (`setContextId:`), drawn on the dark surface.
- A chevron left of them. Its flyout (`TBTrayFlyout`, level 27) holds every other status item (Wi-Fi,
  Spotlight, Control Center, Focus, Display, Battery) as clones too.
- A click on a clone sends a synthetic mouse event to the real item's view in the agent (`[window
  sendEvent:]`), which opens its own menu or popover. Before it, `WXFDropdownAnchor` asks WindowServer
  to put the popup under the clone.

Items are taken in position order, so the pinned one is the rightmost. The bundle identifier ivar of
`SceneHostDisplayItemContainerView` reads null, so identity-based pinning is not done.
Both panels override `constrainFrameRect:toScreen:` (AppKit pushes a window under the notch otherwise).
A right click on an app brings it forward (`activateWithOptions:`, then `openApplicationAtURL:` if the
front did not change) and then shows an `NSMenu` of the titles read from that app's items; picking one
clicks the item.

Verified on the running system (screenshots, `screencapture` works from the shell): panels, clones,
flyout, a clone click opening the Wi-Fi popover. Debug commands (`wxf-taskbar-cmd` in the agent's
container tmp): `tray`, `trayclick <n>`, `menus <pid>`, `activate <pid>`.

## Full menus: the app shares its menu over MIG

MenuBarAgent only has an app's titles, so the tweak is also loaded into the apps the whitelist names
(`TBAppMenu`, host `WXFHostOther`) and the apps share their `NSApp.mainMenu`.

- **Channel (WXFBus).** `SLSSetConnectionProperty` is MIG `_XSetConnectionProperty` (0x187532658): the key
  is at most 128 bytes at +64, the value an out-of-line serialized plist, and `_CGXSetConnectionProperty`
  (0x1872d199c) stores it on the caller's own connection (`CGXConnectionForPort(port)`), whatever
  target was passed, through `CGXSetConnectionUntrustedProperty` (0x1872d1740), which refuses only the key
  `menuBarAppBarInfos`. `SLSCopyConnectionProperty` is `_XGetConnectionProperty` (0x187532770): target
  connection at +32, key at +44, and no check of who is asking. So an app publishes on its own
  connection and the agent reads it from the app's: the connection id comes from one of the app's
  windows (`SLSGetWindowOwner`).
- **App to agent.** Key `WXFTaskbarMenu`, `{pid, seq, name, items}`; an item is `{i, t, e, s, k, m, ind,
  sep, sub}` (TBAppMenu.h). Published when the menu changes (menu notifications, 0.1 s debounce, and a
  0.5 s look while the app is in front, since validation changes without a notification);
  `[menu update]` is called on every menu first so delegates fill Window / Open Recent.
- **Agent to app.** A distributed notification `com.bedtime.WXFTaskbar.invoke` with `{pid, path}`; the
  app walks the indexes from its main menu and calls `performActionForItemAtIndex:`. The sandboxed agent
  can post it.
- **Agent.** `strip:showMenusForApp:` reads the shared menu first; if there is one it pops it up at
  once (the app is not brought forward). Only for an app without the tweak does it fall back to
  bringing it forward and listing its titles.

Verified live with TextEdit: published 8 titles, the agent showed the nested menu with shortcuts,
and a `perform` for Edit > Undo made TextEdit log `performing 'Undo'`. Apps already running when the
whitelist changes need relaunching. Hardened or SIP-protected apps (Safari, Terminal, Xcode) may
refuse the dylib; not checked.

## Open

- The dropdown opens under the item's place in the hidden strip unless the WindowServer half moves
  it (`WXFDropdown`, hooks on `__XSetConnectionProperty`, `__XOrderWindow`, `__XMoveWindow`); that
  half is written from the decompile and unverified until WindowServer is restarted. It now shares
  `_XSetConnectionProperty` with the bus: the anchor hook only reacts to keys starting `WXFAnchor:`.
- Menu items have no icons or images; "AppKit Debug" shows when an app's main menu has it.
- Everything under "WindowServer" above is unverified on a running system.
