# Exposé / Mission Control internals

How WindowServer takes part in Exposé, and why the Exposé and event APIs are built the way they
are. Everything here was read from SkyLight in the dyld shared cache (macOS 27 build in
`~/Downloads/dyld_shared_cache_arm64e.i64`). Addresses and offsets are for that build. Items marked
**unverified** were read from a decompile but have not been seen working on a running system.

## Who draws Exposé

The Dock does, and WindowServer is told what to do. There is no Exposé layout code in SkyLight.
The Dock lays the windows out, then moves the *real* windows with transactions
(`PKGTransaction*`, the op table at `0x1e873d4d0`). The ones that matter:

| Op | Calls |
| --- | --- |
| `SetWindowTransform` | `CGXSetWindowTransformList(conn, &wid, 1, &placement, flags, double[6] affine, 1)` |
| `SetWindowTransform3D` | `CGXSetWindowTransform3DList(conn, &wid, &placement, CATransform3D[16 doubles])` |
| `SetWindowWarp` | `CGXWindow::set_mesh_warp` |
| `SetWindowSystemAlpha` | `CGXWindow::set_window_list_system_alpha` |
| `ReorderWindows`, `SetWindowShape`, ... | |

The only Exposé-specific thing WindowServer keeps is a set of "client advisories"
(`PKGTransactionSetClientAdvisory` -> `WSWindowSessionSetExposeAnimating`, `...SwipeAnimating`,
`...SqueegeeState`, `...DesktopRevealState`, `...SysExAnimating`). They are connection-tracked
overrides in the session data (`+240..+312`). The only reader found is
`-[PKGMenuBarAgentManager rebuildMetrics]`, which turns them into the menu bar's `inExpose` flag.
They do not change how windows are drawn, so a custom view that moves windows itself does not need
them. (The framework leaves them alone; the menu bar will not switch to its Exposé look.)

So a custom Exposé does not have to talk to the Dock. It has to do what the Dock does: apply
transforms to the windows. And it has to keep the Dock from also reacting to the trigger.

## Window transforms

`CGXSetWindowTransform3DList` / `...TransformList` end in
`window_set_transform(conn, window, key, flags, CATransform3D *)` and `window_update_transform`.

- A window has a **stack** of transforms (`window+1960`, 144-byte entries: `key, flags, owner cid,
  0, CATransform3D at +16`), sorted by key. `window_set_transform` replaces the entry with the same
  key (`get_transform_entry`) or inserts one. An identity matrix is stored as identity (the entry is
  cleared in effect). A singular matrix is rejected ("Singular matrix").
- The Dock uses key `0x30000000`. Each call also resets keys `0x1FFFFFFE` and `0x1FFFFFFD` to
  identity.
- `window_update_transform` composes the stack (`concatenate_all_transforms`) into
  `window+1192` (`transform`, `CGXWindow.h`), `+1320` (`system_transform`) and `+1448`
  (`deformation_transform`), and stores the inverse of each next to it.
- **The matrix maps a screen point to the window's untransformed screen position.**
  `CGXTransformPointToWindow` calls `WSWindowTransformProjectScreenPointToWindow(window+1192, p)`
  which multiplies the screen point by the stored matrix (row vectors, homogeneous divide). And
  `ca_window_prep_ingestion_phase` runs `CATransform3DInvert` on it before giving it to the layer.
  The matrix is in global screen coordinates (identity means "as is"), not window-local ones.
  So to draw a window's centre `q0` at `c`, scaled by `s`, you pass
  `p -> (p - c) / s + q0`, i.e. the *inverse* of the picture you have in mind. The framework
  builds the forward matrix and inverts it.
- Perspective: `m34 = -1/d` with row vectors, as in CoreAnimation.
- **Store the inverse of the plane's homography, not of the full 4x4.** WindowServer projects a
  screen point as `(x, y, 0, 1)` times the stored matrix, so a full 4x4 inverse (which needs the
  screen point's depth) puts every rotated card in the wrong place and skews it (the offline test
  put a point at 429,367 instead of 500,350). `FlattenToPlane` drops the z row and column of the
  forward matrix before inverting. Seen in the live video of the cover flow: cards skewed and
  off-centre.
- **Two window lists.** `window data + 32` (length `+40`) is the list the ordering code edits
  (`start_order_window`, `highest_window_at_effective_level`; index 0 is the front). `+56` / `+64`
  is the visible window list the renderer and occlusion code walk front to back
  (`WSUpdaterDeferVisibleWindows` consumes regions from index 0). The visible list is rebuilt at
  the end of every `WSWindowActionGroupPerformWithConnection`, from the workspaces
  (`walk_visible_window_array_workspace_tier`), and each window's order index
  (`workspace +8`) is set from its position in the `+32` list by `update_window_order_info`.
  `CGXOrderWindowListSpaceSwitchOptions` posts notification 1002 ("did change window order",
  handled by `spaces_did_change_window_order_callback`, which runs `update_window_order_info` and
  an action group) but, as `WSWindowUpdateOrderedIn` only acts when the ordered-in state changes,
  reordering windows that stay ordered in left `+56` untouched in the live log (the `asked ...
  @list32/list56` lines: `+32` followed the calls, `+56` never moved), so the picture did not
  change. Calling `spaces_did_change_window_order_callback` after the orders still left `+56` as it was in
  the next live test. The rebuild (`WSWindowActionGroupPerformWithConnection` with `var4` set) has
  two paths, chosen by `*(session+176)`: with `+24` bit 7 and `+20` set ("wmonly") the visible list
  is the window manager's visibility list at `WorkspaceData+64` (a singly linked list of
  `{id, next}` nodes, set by `PKGTransactionSetGlobalVisibleWindowList` ->
  `WSWorkspaceSetWindowVisibilityOverride`, walked by `rebuild_visible_window_array_wmonly`);
  otherwise `walk_visible_window_array_workspace_tier` merges the workspaces, whose per-window
  order index (`window+600 -> +8`) `update_window_order_info` sets from the `+32` positions and
  `update_visible_workspace_ordering_info` sorts. The engine does both: it rewrites the ids in the
  `+64` list in place (direction read from the current visible list; the set of ids is unchanged
  so the override map stays valid), calls `update_visible_workspace_ordering_info`, then the 1002
  handler, and does the same with the original order when the view ends.
- **The order that actually wins (found after that still failed):** the live log said `merging`
  (`*(session+176)+24` = `0x7b`: bit 7 clear, bit 6 set, `+20` non-zero) with a 7-entry override
  list `12 11 3a 46 32 2c 27`, and the stuck visible order was exactly `3a 46 32 2c 27`.
  `workspace_window_list_resort_windows` (run for every workspace by `update_window_order_info`)
  checks bit 6 + `+20` + an override map at `WorkspaceData+56`; with all three it sorts with
  `session_workspace_window_sort::$_0`: windows of different level keys by level, windows of the
  same key that are both window-manager aware (`WSWindowIsWindowManagerAware`) by the map value,
  smaller first, and only otherwise `_less_by_window_order` (the `+8` order index from the `+32`
  list). The map is a `std::unordered_map<uint32_t, ...>` built by
  `create_workspace_visibility_override_map`: header `{buckets, bucket_count, first node, size,
  max_load_factor}`, node `{next, hash, u32 id @+16, u64 index @+24}`, index = position in the
  window manager's list. So the window manager (not window order) decides the stacking of its
  windows, and `CGXOrderWindowListSpaceSwitchOptions` alone cannot change it. The engine hands the
  indices its windows already hold back out in the asked order (`SetOverrideMapOrder`) before the
  resort and rebuild, and in the original order when the view ends.

## Events

Input reaches windows through a pipeline of stages (`sHIDContinuation` = "4-HIDContinuation",
`sAnnotatedContinuation` = "6-AnnotatedContinuation", then `CGXFilterEventToConnection`).
Stage functions do not own the event: they pass it on by calling the next stage, and the poster
frees it afterwards (the hot key code that creates an event frees it right after
`CGXFilterEvent` returns). Not calling the next stage drops the event, the same as an event tap
returning NULL.

Two chokepoints cover every event:

**`CGXCheckForHotKey(SLSEventRecord *)`**, called from
`-[WSKeyEventProcessor annotate_internal:...]`, `-[WSMouseEventProcessor ...]` and
`-[WSGestureEventProcessor ...]` *before* the event is annotated. It gets raw types 1-4, 25, 26
(button down/up), 10, 11, 12 (key down/up, flags changed) and 29-31 (gesture / system defined).
Returns 0 when the event was consumed by a hot key. The callers then do exactly what a swallowed
event needs: a mouse down skips `WSTargetMouseDownFocusWindow` (so the click does not focus or
raise anything), a key event gets no destination. This is also where symbolic hot keys (Mission
Control among them) are matched, so a hook on it sees a key before the hot key table does.
A hot key belongs to the connection that registered it (`WSHotKey+8`), and on a match WindowServer
posts that connection a system-defined event (`hot_key_handle_pressed_event_with_session_data`).
That the owner of the Mission Control keys is the Dock is assumed, not read.

**`sAnnotatedContinuation(SLSEventRecord *, void *)`**, after annotation, right before delivery.
Mouse moved (5), dragged (6, 7, 27) and scroll/zoom (22, 28) never go through `CGXCheckForHotKey`,
so this is where they are seen. Annotation of those has no focus side effects, so dropping them
here is safe.

`SLSEventRecord` fields used (`SLSEventRecord` in the IDB; offsets from the struct):

| Offset | Field |
| --- | --- |
| `+0x08` | raw type (u32) |
| `+0x10` | location in screen coordinates (2 doubles) |
| `+0x30` | u64 (`var6`); used only to recognize the same event twice |
| `+0x38` | modifier flags, CG layout (`& 0xBE0000` is what the hot key matcher uses) |
| `+0x90` | key code (u16), key events (`sHIDContinuation` compares it to a hot key) |
| `+0x91` | button number (u8), mouse events (`CGXCheckForHotKey` indexes buttons with it) |
| `+0x88` / `+0xa4` / `+0xa8` | type 29 with `+0x88 == 24`: symbolic hot key event; id at `+0xa4`, pressed at `+0xa8` |
| `+0x88` / `+0x8a` / `+0x8c` | scroll, type 22: line deltas for axis 1 (vertical), 2, 3 (s16, rounded away from zero) |
| `+0x90` / `+0x94` / `+0x98` | scroll: the same in 16.16 fixed lines |
| `+0x9c` / `+0xa0` / `+0xa4` | scroll: point deltas (s32) |

The scroll offsets come from `create_scroll_wheel_event` (behind `SLEventCreateScrollWheelEvent`),
which writes all three forms. The first version read the fixed deltas at `+0x8c`, one field early,
and scrolling did nothing in the first live test. (`SLSEventRecordGetScrollAcceleratedDelta*` read
a separate appendix at `+224`, which is only allocated when something sets it.)

## Window list

The ordered list of windows lives in the session's window data:
`___sessionControlRef + 32` is the current session (the Mach-O name has three underscores, at
0x1e45915a8; the decompiler shows two, and a lookup with two failed at runtime: the first test
logged `ctl 0`), `+144` its window data, `+56` an array of
`CGXWindow *` (entries can be NULL) and `+64` its length. `CGXGetOnScreenWindowCount`,
`WSWindowListCreateWithListOptions` and `_XGetWindowList` walk it from index 0, and the public
API those serve (`CGWindowListCopyWindowInfo` on-screen) is documented front to back, so index 0
is the front. `**(session+256)` is the cursor window and is skipped. A window's owning
connection is `window+0x30` (`CGXWindowGetOwner` returns `*(window+48)`), and its connection id
`window+0x50`.

**The front application.** `_WSForegroundProcessConnection()` returns the front process's
`CGXConnection *`: `CGXConnectionForConnectionID(CPXGetFrontProcessesConnectionID(1))`, falling
back to the window manager's. `_WSWindowHitTest` tests a window for "belongs to the front
process" by comparing that connection with `window+48`, and the front-application scope does the
same. The first version took the owner of the frontmost level-0 window instead, and the scope
showed every window in the first live test.

## Stacking

Windows are composited in stacking order, whatever z a 3D transform gives them, so a card turned
behind its neighbour is still drawn over it if it is in front in the real order. The engine
therefore reorders the real windows while a view is up: by the layout's `translationZ`, nearest
first, ties in the real order. It orders them back to front, each to the front of its level, with
`CGXOrderWindowListSpaceSwitchOptions(conn, wids, ops, relatives, count, false)`. That function
takes one window list and, per window, a `CGSOrderOp` (1 above, -1 below, 0 out) and a relative
window id, where 0 means the front or back of the level. It looks each window up with
`window_by_id`.

To put the order back, every item records at Begin the window directly below it at the same level.
At the end the items are ordered back to front, each above that window (or to the back of the level
if there was none). Each such window either never moved or has already been put back.

## Dock swipes

The trackpad's system swipes arrive as IOHID `DockSwipe` events (IOHID type 23).
`hid_translation_state_append_hid_event` (case 23, logged as
"hid_translation_state_append_dock_swipe_event") turns each into an `SLSEventRecord` of **type 30**:

| Offset | Field |
| --- | --- |
| `+0x96` | phase (u8, `IOHIDEventGetPhase`, set in `create_translated_event_record_internal`): began 1, changed 2, ended 4, cancelled 8, may-begin 0x80 |
| `+0xa4` | swipe mask (IOHID field 0x170000) |
| `+0xa8` | motion (field 0x170001): 1 horizontal, 2 vertical, 3 scale (IOHIDGestureMotion; enum values from IOHIDFamily, not seen live) |
| `+0xb0` | progress (float, field 0x170002) |
| `+0xb4` / `+0xb8` | position x / y (floats) |
| `+0xcc` | flavor |

`-[WSGestureEventProcessor annotate_internal:...]` calls `CGXCheckForHotKey` for types 29-31
first, and if it returns 0 it sets `noBackground` and stops, so the event-keys hook can claim a
swipe. Otherwise type 30 is routed to the window manager's connection (`session+176 → +16`, the
Dock) with forced routing. The gesture processor tests the phase byte with `& 0x80`, `& 1` and
`& 0xC`, which is where the bit meanings come from.

The Dock decides what a swipe means, so the **sign of `progress` for "up"** is not in
WindowServer. The first live test showed that a swipe up gives a **positive** progress (the first
guess, negative, was flipped). The example keeps the sign in one constant (`kSwipeUpSign`) and logs
every swipe's values.

Displays: `PKGDisplayBestMatchingPoint(CGPoint)` returns the display for a point,
`PKGDisplayGetMain()` the main one, and `PKGDisplayGetBounds(display)` a `CGRect` (read from
`display+8`). `PKGWindowGetDisplay(window)` is the window's.

## Activation

`CPXGetConnectionPSN(connection_id, &psn)` gives the process serial number of a connection (it
reads `ProcessRec+4`), and `CPXSetFrontProcess(psn, const SLSEventRecord *event, uint32_t flags)`
makes that process frontmost (`_CGXSetFrontProcess` is the RPC wrapper that first checks
`isProcessEligibleForSetFront`). `PKGSetFrontProcessForCurrentSpaceSwitch` calls it from inside
WindowServer as `CPXSetFrontProcess(psn, NULL, 0x800)`, so it needs no event. Flags seen in
`SetFrontProcessInternal`: `0x100` also brings all the app's windows forward, `0x800` does not
unhide a hidden process, `0x200` and `0x400` are carried into the activation notice. The engine
passes 0: the selected window is ordered to the front by the engine afterwards. The connection id
is not `window+0x50` (that reads 0, so the first live test got -600, procNotFound). As
`pkg_space_switch_for_window_order_top` does, take the connection at `window+0x40` if set, else
`window+0x30`, and read the id at `connection+0x50`.

## The windows behind

Every window on the display that does not take part (other applications' in the front-application
scope, anything `includeWindow` refused, the desktop picture and icons, the menu bar, the Dock) is
offered as a background item with its level and an alpha factor. The engine applies the factor
through `update_alphas` on `window+488`, as for the cards, and puts the window's own alpha back
when the view ends.

## A backdrop window (tried, removed)

A server-owned window hosting a tweak's `CALayer`, built like `WS::create_shield_window_common`
(`CGXWindow::new_window(NULL, 5, region, 6145)`, a local `CAContext` bound with
`CGXWindow::bind_local_ca_client_context`, `WSWindowSetSystemWindow` / `WSSystemWindowRelease`),
optionally with the window background blur (radius at `window+1968`, style bit 1 of `+2400`, hint
at `+1972`, as `_XSetWindowBackgroundBlurRadius` stores them). In the live test it did not crash,
but every window ended up clipped to a rectangle in the middle of the display and misplaced, and
the session stayed broken until WindowServer was restarted. Committing only the backdrop's context
(`setCommittingContexts:`) was suspected and removed, and that did not fix it. The cause is not
known, so the backdrop was taken out. Anyone retrying: begin with the window alone (no layer, no
blur), then add one piece per test.

## What is not done

- **Backdrop, labels, spaces.** Nothing of the framework's is drawn (see "A backdrop window").
  Other spaces and minimized windows are not part of the view.
- **Stacking in the live test.** The middle card was still reported as not on top although the log
  showed the ordering calls going through in the intended order. `CheckStacking` now reads the real
  window list back after each reorder and logs `stacking not as asked` if it differs. Until that
  line (or its absence) is seen, the cause is open: the list may be right while the compositor draws
  in another order.
