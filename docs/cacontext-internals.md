# CAContext internals

How WindowServer learns which `CAContext` an application window is drawn into, and how
`WXFCAContextRetriever` gets at it. Everything here was read from SkyLight in the dyld shared
cache (macOS 27 build in `~/Downloads/dyld_shared_cache_arm64e.i64`). Offsets are for that build.

## Where the context id comes from

An application owns a `CAContext` and tells WindowServer its id over RPC. Two handlers take it,
and both call the same function:

| Handler | Call |
| --- | --- |
| `_XCreateWindow` (`0x1875388d8`) | `WSWindowBindRemoteCAClientContext(window, v10)` right after `CGXWindow::new_window` |
| `_XSetWindowLayerContext` (`0x187538c54`) | `WSWindowBindRemoteCAClientContext(window_by_id(a1[8]), a1[9])`, if `connection_holds_rights_on_window` |

`WSWindowBindRemoteCAClientContext(CGXWindow *window, uint32_t contextID)` (`0x187401774`, 0x124
bytes) does nothing unless `window[1] == 5` (`window_type`, the CA-backed kind). Then:

- feature `WindowServer/CAWindowContent` on: `CGXWindow::initialize_ca_content_for_context(window,
  contextID, 1)`. This builds the `WS::CAWindowContent` at `window+24`, stores the id at
  `content+88`, and gives it to the "Client Content Host" layer host with `setContextId:` (and to
  the "Window" `CAWindowLayer` as its client context id). It also writes `window id` to `content+0`.
  A second bind frees the old content and builds a new one, so the id **can change** during a
  window's life.
- feature off: `WSCALayerBackingInitialize(window, contextID)`.

`initialize_ca_content_for_context` has only two callers: this function and
`CGXWindow::bind_local_ca_client_context`. `WSCALayerBackingInitialize` has the same two. So hooking
`WSWindowBindRemoteCAClientContext` sees every application context in both feature states, and
sees nothing else.

`content+72` is a different id: the server's own local `CAContext` for the window ("Server root"),
created inside `initialize_ca_content_for_context`. It is not what the retriever reports.

## Not covered

`bind_local_ca_client_context(window, CAContext *, bool, bool)` is the path for windows
WindowServer makes for itself (`create_shield_window_common`, the menu bar rebuild,
`PKGSystemStatusIndicatorsCreateAndBindContext`, corner windows, the cursor). Those windows are not
reported. A context id of 0 passed to the bind function means "no client context"
(`initialize_ca_content_for_context` special-cases `a2 == 0`), so the entry is removed.

## Window teardown

`CGXWindow::~CGXWindow` (`__ZN9CGXWindowD2Ev`, `0x1873e7c7c`; there is no D1) has exactly two
callers: `CGXWindow::release_window` and the failure path of `CGXWindow::new_window`. The hook
reads `window->window_id` first, drops the map entry, then calls the original.

## What the framework does

`api/WXFHooks.c`, group `WXFHookGroupCAContext`, installed from `WXFHooksInstallAll` so the map is
complete for every window made after `SetupFramework`:

| Hook | Symbol |
| --- | --- |
| `WXFCAContextHook_Bind` | `_WSWindowBindRemoteCAClientContext` |
| `WXFCAContextHook_Destroy` | `__ZN9CGXWindowD2Ev` |

Bind calls the original, then, for `window_type == 5`, records `window_id -> contextID` and calls
every registered retriever's callback if the pair is new. The map and the list of retrievers are
process-wide (the framework is shared by every tweak). Callbacks run on WindowServer's main thread
with no framework lock held.

## Pointing a window's host at another context (tried, removed)

The example first took over an existing window's content host to show another window, and the user
asked for clones instead; the takeover was removed. What was read for it stays here. Read from `initialize_ca_content_for_context` (`0x1873e9f14`) and
`ca_window_prep_ingestion_phase` (`0x187194154`):

| Where | What |
| --- | --- |
| `window+24` | the `WS::CAWindowContent` (null for non-type-5 windows, or with the feature off) |
| `content+0` | window id |
| `content+64` | the server's local `CAContext` for the window (`+[CAContext localContextWithOptions:]`) |
| `content+72` | that context's id |
| `content+88` | the application's context id (the one the retriever reports) |
| `content+104` | "Client Content Host", the `CALayerHost` with `setContextId:` = `content+88` |

`content+104` has its `contextId` set once, in `initialize_ca_content_for_context`. Ingestion only
re-sets its `bounds` (from `content+288..312`) and never its transform, and the other hosts it
makes ("Window Manager Host" `+112`, "CGSSurface-Above/Below Host" `+120/+128`) are separate layers.
So a later `setContextId:` on `+104` is not undone by ingestion, and a transform on it survives.

WindowServer commits a change to a window's layers with `WSCAContextScopeTransaction`
(`0x1872ae2dc` / `0x1872ae34c`): `+[CATransaction begin]`, `setDisableActions:`, `setDisableSignPosts:`,
the change, `setCommittingContexts:` with the contexts from `addContextToCommit` (here `content+64`),
`+[CATransaction commit]`. The example repeats that sequence directly.

The takeover worked, but the hijacked window **kept freezing even with the 60 Hz pulse below, while a
clone of the same window did not** (live test, 2026-10-27). So a host whose `contextId` is changed
after creation is not repainted like one that was bound at creation; why is not known. Sizes were
matched with an affine transform on the host, a guess about how a `CALayerHost` lays out remote
content that worked well enough to see.

## Why the takeover froze

The first live test of the takeover worked but froze often. Mirror targets were never covered by other
windows, and **the source kept updating while the mirror was stuck**, so the app was not being
throttled; the mirror simply was not repainted.

`updateWindow(connection, window)` (`_updateWindow`, `0x1873860d0`; `WXFWindowUpdate` calls it) does,
if `CGXWindowIsVisible(window)`: `CGXInvalidateDisplayShape(connection, window,
CGXCreateScreenVisibleFrameShapeForWindow(window))`, then `CGXScheduleUpdateAllDisplays(connection, 0,
"WindowFilterUpdate")`. That is the window-level "this region changed, redraw it". An application's
commit does it for the application's own window (the context is tracked by `WS::CA::TrackContext`,
and `initialize_ca_content_for_context` keeps `contextId -> window id`); nothing does it for a
window that merely hosts someone else's context. `CGXInvalidateDisplayShape` has an explicit branch
for a NULL connection. The example therefore calls `updateWindow` on every mirror target and clone
at 60 Hz while any exist. **Live: the pulse keeps a clone live, but did not cure the takeover** (above).

The other things read on the way, not tied to the freeze:

- **Occlusion of the source.** `WSPackagesPerformOcclusionPass` (`0x187337f8c`) walks the window
  list front to back, accumulating the opaque shapes of the windows in front, and calls
  `CGXPackagesNoteWindowIsVisible(window, visible)` (`__ZL30CGXPackagesNoteWindowIsVisibleP9CGXWindowb`,
  `0x187337d4c`) for each. That sets bit `0x10000000` of `window+2400`, calls
  `CGXWindow::reevaluate_screen_state` (`window+2272` becomes 3 when visible, 2 when on screen but
  occluded, 0 when ordered out), adds +1/-1 to the owner connection's visible-window count
  (`CGXPackagesConnectionAddVisibleWindowCount`) and, if the window asked for them
  (`window+2408 & 0x200`), posts notifications 912 (visible) / 913 (occluded) to the connection.
  This applies to the **source's own window**, which the mirror target may be covering. A hook on
  `CGXPackagesNoteWindowIsVisible` that passes 1 for chosen windows would stop the app being told it
  is hidden. Unproven as the cause.
- **"Active offscreen".** `PKGTransactionSetWindowIsActiveOffscreen` (`0x18745cde0`) sets bit
  `0x400000` of `window+2400` for a client, undone when the client disconnects. What reads the bit
  was not found.
- **Context tracking.** `initialize_ca_content_for_context` records `contextId -> window id` for both
  the server's and the client's context in the session's context map (value at entry+20), and calls
  `WS::CA::TrackContext(ctx, connection, options)` (`0x187151d38`), which registers render-server
  callbacks for the context through `CARenderContextById`. A mirror target has no such registration
  for the source's context. Whether that matters for repainting is not known.

## Clones: a window of our own that hosts an application's context (CAContextExample, `C`)

Built from the pieces read above, not yet run:

1. `CGXWindow::new_window(NULL, 5, region, 6145)` (`__ZN9CGXWindow10new_windowEP13CGXConnection14CGSBackingTypeP15CGSRegionObjecti`,
   `0x1873e62e8`) as `WS::create_shield_window_common` (`0x1870b5510`) calls it. The region is
   `CGRegionCreateWithRect(frame)` in screen coordinates; `CreateCloneOfWindow` passes its frame the
   same way. The caller releases the region.
2. `WSWindowBindRemoteCAClientContext(window, contextID)`: for a type-5 window this reaches
   `initialize_ca_content_for_context(window, contextID, 1)`, the same call `_XCreateWindow` makes
   for an application's window. A NULL connection is handled there (the process id falls back to
   `getpid()`, the connection counters are skipped when there is none, and the
   `TrackContext(ctx, NULL, options)` assertion needs bit 0 of the options, which is clear for 6).
3. Order above the source with `CGXOrderWindowList...` as the drag code does, and remove it as the drag
   code removes its snapshot: ordered out with a NULL connection, `WSSystemWindowRelease` 0.1 s later.

`WXFCAContextHook_Bind` ignores windows without a connection (`window+0x30`), so a clone is not
reported by the retriever as a second window drawing the source. The shield windows use the same
creation but bind a local context with layers made in the tweak's process. The old backdrop attempt
(docs/expose-internals.md) did that, plus a blur, and broke the display for a reason nobody found.
The clone differs (a remote context, no layers of its own, no blur), but nothing here shows what
actually went wrong there, so a clone breaking the display would not be a surprise.

## Not yet verified live

Nothing has been run inside WindowServer yet. To check: restart WindowServer, open an app window,
and confirm that the callback fires with that window's id and that `ObtainContexts` has it. The key is `CGXWindow.window_id`
(`*window`); that it equals the `CGWindowID` an app sees is assumed, not read, so check it too.
For the example: that closing a source removes its clone, that an application which swaps its
context shows up in the clone, and what the clone looks like with a window that has a shadow or
rounded corners (the clone's shape is the plain rectangle it was made with). Also worth confirming that closing the window
removes the entry, and that an app which swaps its layer context shows up a second time.
