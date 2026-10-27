# Window decor internals

How `WXFDecor` puts visuals of its own (horns, ears, borders, badges) on application windows. Read
from SkyLight and QuartzCore in the dyld shared cache (macOS 27 build in
`~/Downloads/dyld_shared_cache_arm64e.i64`); addresses are for that build.

## Where the layers go: the window's own server tree

`CGXWindow::initialize_ca_content_for_context` (`0x1873e9f14`) builds a `WS::CAWindowContent` at
`window + 24` for every type-5 window (feature `WindowServer/CAWindowContent`):

| Offset | What |
| --- | --- |
| `content + 64` | WindowServer's local `CAContext` for the window (`localContextWithOptions:` with `WSCAContextServerOptionsDontNotify`) |
| `content + 136` | "Server root", that context's layer, `masksToBounds:0` |
| `content + 144` | its only sublayer: shadow and corner properties, and below it `+160` → "Window" `+152` (`CAWindowLayer`) → "Client Content Host" `+104` (the application's context) |

`initialize_ca_content_for_context` calls `addSublayer:` on the root once (`+144`). Nothing else in it, in
`ca_window_prep_ingestion_phase` (`0x187194154`) or in any `CAWindowContent` function touches the root's
sublayers. Ingestion only sets the root's position `(0,0)` and bounds `(0, 0, w, h)` (from
`content + 272..312`, flag 8) and its transform (the inverse of the window's transform, flag `0x20000`).

Decor inserts a container at index 0 of the root (behind the shadow and the window) and one at the top
(over the window's content). Elements live in those. They are part of the window's tree, so they move,
resize, stack, fade and transform with the window in the same frame, and are drawn outside its bounds
(nothing on the way masks to bounds). The containers sit at the root's origin, so element positions are
window-local.

A new `initialize_ca_content_for_context` (the application binds a new context) frees the content and
builds another; the tick sees `window + 24` change and moves the containers into the new root.

**Repainting.** The window's context is DontNotify, so a commit of ours doesn't tell the server. After
changing a window's elements the tick calls `WXFWindowUpdate` (`updateWindow`: invalidate the window's
visible shape and schedule a display update), as the application's own commit would.

**Orientation.** The tree's origin is the bottom left, y up. The shield's debug label is pinned with
`CAConstraint`s to `MinX + 20` and `MaxY - 20` (`WS::create_shield_window_common`), and decor laid out on
that assumption sat right, live.

## The clip at the shadow's edge: the window's render bounds

Live, decor stopped at the edge of the window's shadow, higher for the active window (bigger shadow).

Each window's tree is rendered by its own render update. `defenestrator3::ca_prepare_begin_window_update`'s
block calls `CARenderUpdateBegin2(..., bounds, ...)` with a `CGRect` from the window's update state
(`state + 136`) and then `CARenderUpdateAddContext2` with the window's server context (`content + 72`).
Nothing outside that rect is rendered. `ca_window_prep_ingestion_phase` writes the rect at its end
(`v188[17..20]`): for a window without a mesh, `CGXWindow::frame_bounds()` (`0x1873eba2c`), offset by
minus the shape's origin, outset by `tunables::non_clamping_backdrop_max_outset`, mapped through the
inverse layer-to-window transform; with a mesh, `MeshGetBounds(CGXWindow::frame_mesh())`.

`frame_bounds` computes, on its own: the shape's bounding box (`window + 384`, `window->shape`), and if
the window is shadowed, the union of that box grown by `WSWindowShadowRadius` and offset by the shadow's y
offset (`WSWindowShadowCurrentPropertiesPtr + 24`) with the box grown by the shadow's other extent
(`+12`). It does not use `CGXCopyScreenFrameShapeForWindow`, which is why hooking that changed nothing.
Callers: ingestion, `ca_prepare_set_window_backing_update_parameters`,
`ca_backed_window_create_source_shape_direct`.

Hook `WXFDecor FrameBounds` (`__ZNK9CGXWindow12frame_boundsEv`, returns a `CGRect` in d0-d3) unites the
original with the decor's bounds, placed at the shape's bounding box origin.

Ruled out on the way: layer hosts (WindowServer makes only "Client Content Host", "Window Manager Host"
and the two CGSSurface hosts), the structural regions (event routing; a window's region is its plain
rectangle, `CGXWindow::finish_layer_update`), and the root layer's bounds.

## The frame shape: damage and visibility

Live, the horns were cut off a little above the window, higher for the active window than for an inactive
one: at the edge of the shadow. Each window's tree is composited as a structural region whose shape comes
from `CGXCopyScreenFrameShapeForWindow(window, systemOffset)` (`0x1872ad070`): the window's combined clip
shape grown by the shadow radius (and offset by the shadow's y offset), cached in the window's shape data
by screen-geometry seed, returned +1. With `systemOffset` the shape is shifted by minus the translation
of the system transform (`WSWindowGetSystemTransform` copies `window + 0x528`). Every visible, unobscured
and trusted-unobscured shape is made from it (`CGXCreateScreenVisibleFrameShapeForWindow` and friends), and
so is the region `CAWindowContent::finish_binding_layer_host_shapes` gives the window's context (intersected
with `WSWindowGetGlobalClipShape`). Hit testing uses the content shape, not this one.

The shape (and the visible/unobscured shapes made from it) is cached by the window's screen geometry
seed (`window + 196`), so a hook alone changed nothing live: the caches were made before the decor existed.
When a decor's bounds change, the tick calls `CGXWindow::invalidate_shadow_and_schedule_update(window,
connection)` (`0x1873ee9e8`: seed + 1, `CGXWindowPluginLayerInvalidate`, `invalidate_shadow_frame`,
`CGXScheduleUpdateAllDisplays`), what the server does when a shadow changes. Other seed bumps, read on the
way: `set_shape_internal`, `set_opaque_shape`, `update_alphas`, `CGXWindowGeometryInvalidate`.

Hook group `WXFHookGroupDecor` wraps it: for a decorated window it returns the original shape united with
the decor's bounds (published by the tick in window-local points, offset by the window's frame origin and,
with `systemOffset`, by minus the system translation). The hook may run off the main thread, so it reads
the bounds under an `os_unfair_lock` and nothing else of decor's.

## Behind the window: inside the shadow layer

Live, a horn tucked under the window showed a light seam where it met the window's edge. The shadow layer
(`content + 144`, the root's only sublayer, parent of the window `+160`) is given `setPunchoutShadow:1`
by ingestion, and the punch-out clears what is behind the window within the window's own render; the
window's translucent edge then showed the wallpaper instead of the horn. The behind-container now sits
inside the shadow layer at index 0: drawn after its shadow and punch-out, under the window.
`initialize_ca_content_for_context` gives `+144` its one sublayer (`addSublayer: +160`) and
`masksToBounds:0`; nothing rearranges its sublayers after that. The container is positioned at
`[shadowLayer convertPoint:(0,0) fromLayer:root]` on every layout, so element coordinates stay the root's.

## The application's name and bundle

`proc_name` fails inside WindowServer. `CGXGetConnectionAppName(cid, buf, len)` (`0x1872d1ad4`) gives the
process record's name (`CPXGetProcessName`: record `+56`). `CPXCopyConnectionApplicationInformationItem(cid,
key)` (`0x1870bb1d0`) returns `_LSCopyApplicationInformationItem(session, record + 88, key)`; WindowServer
uses it for `kLSLaunchEventRecordTimeKey` and others. Decor asks it for `kLSDisplayNameKey` and
`kLSBundlePathKey` (exported from LaunchServices) to fill `WXFDecorWindowInfo.appName` and `bundlePath`.

## Core Animation inside WindowServer: the display freeze

The first decor build (and the old Exposé backdrop) left only the wallpaper and the cursor on screen
while WindowServer's main thread kept running. Both changed `CALayer`s without an explicit transaction.

- `CA::Transaction::ensure_implicit(bool)` (`0x18b201304`) runs when a layer is changed with no
  transaction open: it adds a run-loop observer and pushes an **implicit transaction** on the thread.
- WindowServer commits its layer changes through `WSCAContextScopeTransaction` (`0x1872ae2dc` /
  `0x1872ae34c`): `begin`, `setDisableActions:`, `setDisableSignPosts:`, the change,
  `setCommittingContexts:` with the contexts touched, `commit`. It is the only caller of
  `setCommittingContexts:` in SkyLight.
- With an implicit transaction under it, each of those is nested and its commit is deferred to the
  implicit one, which WindowServer's main thread never commits. Nothing reaches the screen again.

Rules in `WXFDecor.m` (`CAScope`):

1. Every `CALayer` is created, changed **and released** inside an explicit transaction with its own
   autorelease pool, committing only the decorated windows' contexts, as `WSCAContextScopeTransaction`
   does. Lookups that may drop the last reference to a layer happen inside the scope.
2. Nothing that opens its own `WSCAContextScopeTransaction` (binding, ordering) is called inside one.

## Which windows rules decorate

An application's context is bound in `_XCreateWindow`, before the window is sized, levelled and
ordered in. Rules decorate a window only when it is type 5, level 0, owned by a connection, at least
64x48, on screen (`screen_state`, `+0x8e0`, non-zero), has a `CAWindowContent`, and doesn't cover its
whole display (login and full-screen backdrops). Windows that don't qualify yet are looked at again
twice a second until they do or close. Live: before this, rules caught 500x500 windows at creation that
never showed, and the 1800x1169 login backdrops.

## Tried and dropped: a companion window per decorated window

The first working build drew decor in windows of its own ("planes") next to the target, made like
the server's shields (`new_window(NULL, 5, region, 6145)`, a local context,
`bind_local_ca_client_context`). What was learnt on the way:

- **Context options.** With DontNotify a plane never showed its later commits; Notify
  (`WSCAContextServerOptionsNotify`, as `PKGSystemStatusIndicatorsCreateAndBindContext` uses for the
  recording indicators) made it show.
- **Transforms.** `window->transform` (`+0x4a8`) is the composed stack including WindowServer's key-0
  base translation by minus the window's origin (`CGXWindow::set_shape_internal`, `0x1873eb084`), so it
  is not identity at rest. Copying it to a plane added the window's position twice.
- **Stacking.** `session_workspace_window_sort`'s comparator (`0x187220814`): for windows both ordered
  in, key `level << 16 | (sublevel + 0x8000)` (sublevel is the int16 at `+40`) first, higher in
  front; on equal keys a window the window manager isn't aware of (`WSWindowIsWindowManagerAware`) goes
  in front of one it is; between aware windows, their index in the window manager's override map
  (`WorkspaceData + 56`). A plane, unknown to the window manager, sorts in front of every application
  window of its level whatever it is ordered relative to. Sublevel -1 put planes behind everything but,
  live, the horns still weren't behind their window.
- **Lag.** Planes followed a tick late; every move ends in `CGXMoveWindowList` (`0x1873f88d8`), which
  a hook could mirror. In the window's own tree none of this is needed.
- **Clicks.** Planes kept out of hit testing with tag bit `0x200` (`_WSWindowHitTest`, `0x1873f9448`);
  decor matched clicks against its layout in the `WXFEvent` mouse hook. It never worked live and was
  dropped on request.

## Not verified live yet

Horns behind the window, moving with it, live. Not yet: the frame shape hook (decor past the shadow),
a rebuilt tree, Exposé/Niri transforms (the added bounds are untransformed).
