# Menu bar internals

How WindowServer places and draws the menu bar, and where to hook to change its height or move it
to another screen edge. Everything here was read from SkyLight in the dyld shared cache (macOS 27 build in
`~/Downloads/dyld_shared_cache_arm64e.i64`). Addresses are for that build. Items marked
**unverified** were not seen in a decompile, or were not seen working on a running system.

## One function decides the rectangle

`menu_bar_bounds_for_space(PKGManagedMenuSpace *)` (`__ZL25menu_bar_bounds_for_spaceP19PKGManagedMenuSpace`,
`0x1873323f8`) returns the bar's rect in d0-d3. Read from the disassembly:

- Origin and width come from the display: `PKGManagedMenuSpaceGetMenuBarDisplay(space)` gives a
  `PKGDisplay`, whose bounds are four doubles at `+8..+40`. (When `session->+0x240->+0x10 == 1` the
  bounds are the bounding box of `PKGManagedSpaceCopyManagedShape` instead.)
- The height is **not** the display's: it is the `uint32` at `PKGDisplay+0x28` (the menu bar height),
  unless the bounds equal `CGRectZero`.
- `WSDefaultMenuBarHeightInPoints` is 30 with Solarium, 24 without. On a notched display
  `WS::Displays::Display::evaluate_display_parts` sets `Display+504` from the notch height instead
  (`WSDisplayGetMenubarHeight` reads it).

So the bar is "the top `height` points of the display" and nothing else is stored.

Callers of `menu_bar_bounds_for_space` (13) - every one of them follows a hook on it:

| Caller | What it does with the rect |
| --- | --- |
| `reposition_one_menu_bar` (`0x18733bb0c`) | Moves/reshapes the menu bar window (`WSWindowMove` / `CGXWindow::shape_window_with_rect`), sets its clip shape, walks the companion windows |
| `_XGetMenuBar` (`0x18753ba4c`) | MIG reply to clients: x, y, width, height of the main display's bar |
| `_XGetRevealedMenuBarBounds` (`0x18753fff0`) | Same, for the revealed bar |
| `CGXFullMenuBarRect` (`0x187332608`) | Used by `RepositionAndClipStatusItemList` (status items) and by `PKGEventsMoveTiledSpaceWindowDrag` |
| `windowDragCreateAllowedAndMenuBarRegions` block 42 (`0x187291740`) | Adds the bar rect (height +1 when `session->+380/+381`) to the region windows can't be dragged into |
| `SolariumMenuBarContext::ingest_scratch_data` (`0x18738e710`) | Fills layer geometry from the **width** and the passed height only |
| `Underbelly::rebuild_window_and_ca_context`, `PKGManagedMenuSpaceUsesStationaryMenuBar`, `PKGManagedMenuSpaceSetNeedsMenuBarRebuildType`, `managed_menu_space_synchronized_set_menu_bar_reveal`, `managed_space_set_main_window`, `PKGWindowDidMakeSpaceCurrent`, `WSCaptureMenuResolveDesktopChanges`, `sub_1875BAA40` | Not read in detail |

## Moving the window

`reposition_one_menu_bar(space, double *outHideOffset, double reveal)` is called from
`PKGRebuildMenuBarsIfNeeded`. With `(x, y, w, h)` from the bounds function:

- `hide = round((1 - reveal) * (h + min(maxCompanionHeight, maximumCompanionWindowOffset)))`, and the
  window is placed at `(x, y - hide)`. So the auto-hide slide is **always upward**; `reveal` is
  0..1 and above 1 means "stationary" (hide = 0).
- If the window's size already equals `(w, h)` it is moved with `WSWindowMove`; otherwise it is
  reshaped with `shape_window_with_rect` and `update_menu_bar_opaque_shape` runs.
- The clip shape is the intersection of the bar rect and the hidden rect, offset into window space.
- Companion windows (app menu items, the Apple logo, ...) are positioned by
  `PKGManagedMenuSpaceWalkMenuBarCompanionWindows` with `(x, y, w, h, hide)`.

## Drawing

With Solarium (`WS::Features::solarium_menubar_enabled`) the bar is a `SolariumMenuBarContext`
(`reshape_layers` at `0x18738ba4c`, `update_layers` at `0x18738bc18`): CALayers laid out as a
horizontal strip (a left piece of width `a2`, a right piece, a background of `(0, a4, w, h)`).
**Unverified:** whether anything in there can be rotated; apps draw their own menu titles and
status items horizontally.

## What the framework does (WXFMenuBar)

Only the height is offered. `WXFMenuBarHook_Bounds` wraps `menu_bar_bounds_for_space` and replaces
the height of the rect it returns (unless the rect is `CGRectZero`). A change calls
`set_needs_rebuild_menu_bars_passing_test(16, test)`, the same call
`CGXPackagesUpdateMenuBarForManagedSpace` makes; the block adds `0x400` and schedules
`rebuild_menu_bars_callback`.

Not seen on a live WindowServer yet. `Display+504` (`WSDisplayGetMenubarHeight`) still holds the
system height; it feeds the CA display metrics and the notch safe area, which this does not touch.

## Moving the bar to another edge (not implemented)

An edge setting was written for the bottom and taken out again; this is what it found.

Hooking `menu_bar_bounds_for_space` is enough to move the rect for the window, the drag region,
the status item layout and what clients are told. For the bottom edge the rect is
`(strip.x, strip.y + displayHeight - h, w, h)`, with `displayHeight` from
`PKGDisplayGetBounds(PKGManagedMenuSpaceGetMenuBarDisplay(space))` (four doubles at
`PKGDisplay+8`, read from the disassembly of both). It does not change the upward auto-hide
slide, the horizontal layout of app menus and status items, or the layer layout, and these would
have to be handled:

- **Auto-hide direction.** `reposition_one_menu_bar` always places the window at `y - hide`, and
  clips the visible part as the bottom `h - hide` of the window. A bottom bar would need the move
  reflected (`2 * y - y'`), the clip set to `(0, 0, w, h - hide)` afterwards, and the companion
  windows (`block_invoke_2`, which put them at `max(y + h - hide, y - offset)`, i.e. hanging
  *below* the bar) mirrored too.
- **Hover reveal.** The reveal of an auto-hidden bar comes in as `SLSTransactionSetSpaceReveal`
  from another process; nothing in WindowServer watches the top edge. Not traced.
- **Client work area.** `_XGetMenuBar` reports the rect, but whether AppKit's
  `NSScreen.visibleFrame` and zoom use it, rather than assuming the top, is decided in the client.
- **Left and right.** The content (app menus, Apple logo, status items) is horizontal, so it would
  need rotating first.
