# Drag animation internals

How WindowServer draws a dragged window, and why the drag-shader API is built the way it is.
Everything here was read from SkyLight in the dyld shared cache (macOS 27 build in
`~/Downloads/dyld_shared_cache_arm64e.i64`). Offsets are for that build.

## Two compositors

WindowServer draws windows two ways.

**CoreAnimation path (almost every app window, `CGXWindow` kind 5).**
`WS::Updater::defenestrator3::ca_window_prep_ingestion_phase` turns each window into layer state
on a `WS::CAWindowContent` (`window+24`), built by `CGXWindow::initialize_ca_content_for_context`:

```
content+136  root          <- setOpacity:, setMeshTransform:
  content+144  "Shadow"
    content+160  "Hosting"
      content+152  "Window" (CAWindowLayer)
        content+104  "Client Content Host"   (the app's live context)
```

CoreAnimation renders these. The Metal ubershader path below never sees them:
`MetalBacking::DetermineShaderOptions` is not called for a kind-5 window.

Per window, the ingestion applies:

| Layer property | Source | Notes |
| --- | --- | --- |
| root `opacity` | `clamp(window[488] * window[492] * window[496])` | read every ingestion, no gate |
| root `meshTransform` | `WSCAMeshFromWSMesh(CGXWindow::frame_mesh, bbox(window+384))` | rebuilt when `window+208` changes |
| `colorBrightness` filter | `window+2140` | |
| `gaussianBlur` filter | `window+2200` | |

**Metal path (windows WindowServer draws itself).** For example, clones made by
`CreateCloneOfWindow`. `generate_layers_for_window` copies `CGXWindow::filter` onto the layer
(+0x228 type, +0x230 params). A type-2 filter makes `DetermineShaderOptions` set option bit
0x10, and `ShaderComposer::UberComposite` can then be answered with a pipeline built from a
developer's metallib. That is the only place a custom Metal fragment shader can run.

## Why the drag shader uses a stand-in

A custom shader can't run on a live CA-backed window, because that window never reaches the
Metal path. So while a window with a shader is dragged:

1. `CreateCloneOfWindow(window, frame + margin, display, true)` makes a snapshot window. This is
   a one-shot capture (`SystemStatusBar`'s clone helper), so its content does not update.
2. The developer's shader is attached to the clone with the type-2 filter, and runs through
   `UberComposite`.
3. The real window is hidden through its alpha. `CGXWindow::update_alphas(window, conn, 0, a1,
   a2, true)` stores the factor, and the next ingestion sets the root layer's opacity, so the
   shadow is hidden too. `CGXSetWindowListAlpha` is not used because it only acts on windows set
   up for server fades (`window+2405 & 0x40`).
4. `CGXMoveWindowList(conn, &cloneID, 1, 0, dx, dy)` moves the clone with the window. This is the
   same function the drag code reaches through `WSMoveWindowWithGroupByOffset`.
5. At the end, the alpha is restored, then the clone is ordered out and released 100 ms later.

## Things that look like they hide a window but don't

- `CGXWindow::update_ca_visibility(window, bool)`: the bool only says whether to commit.
  Visibility is recomputed from the window's visible shape, and only controls whether the
  client context keeps updating.
- Alpha on the Metal path: `update_alphas` only invalidates when `window+2407 & 4` is set. This
  is the "dead end" the Vanish notes describe. It does not apply to CA-backed windows, whose
  opacity is read straight from the factors.

## Live deformation (not used by the shader API)

`CGXWindow::set_mesh_warp` on a CA-backed window becomes a `CAMeshTransform` on the root layer.
This deforms the live window, with no snapshot. Coordinates:

- Mesh `local` is content-relative points. `frame_mesh` (`MatchRectToMeshWithTextureRect`)
  extends it over the shadow frame by extrapolation.
- Mesh `global` is absolute screen points. `WSCAMeshFromWSMesh` normalises it against
  `bbox(window+384)`, the window's current frame. So a mesh built for one position is wrong as
  soon as the window moves.
- The root layer's bounds come from `MeshGetBounds(frame_mesh)`.
