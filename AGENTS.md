# Agent notes

WindowServerFramework is a framework that tweaks load into WindowServer through Ammonia. The
tweaks hook SkyLight internals. Most of the work is reverse engineering, and most past mistakes
came from guessing how WindowServer behaves instead of reading it. These notes are about how to
do that work.

## Ground every claim in the binary

- **Read before writing.** Before writing code that depends on a WindowServer function, field
  offset or code path, decompile the function and its callers. A Vanish comment, a symbol name
  or an earlier note is a lead, not a fact.
- **Use the right database.** The IDB needs to be created with this machines `dyld_shared_cache_arm64e`, 
  if you can not find the IDB. Other `.i64`s on this machine are different builds with different addresses 
  and offsets.
  - Before creating a new database, ask if the user if they have to one to provide.
  - Open it with the IDA MCP `open_database`. It has to be reopened after the server
    disconnects.
  - If an address doesn't decompile to the function you expect, you have the wrong/old database.
- **Find functions by name, not address.** Look up raw Mach-O names with
  `ida_name.get_name_ea(BADADDR, "__ZN9CGXWindow…")`. The framework resolves the same names at
  runtime with `WXFResolveServerSymbol`, so a name that resolves in IDA resolves in the tweak.
- **Follow the data, not the name.** A function called `update_ca_visibility(win, bool)`
  ignores its bool for visibility. Trace which field the renderer actually reads.
  - For CA-backed windows, `defenestrator3::ca_window_prep_ingestion_phase` is where window
    fields become CALayer properties.
  - For server-drawn windows, `generate_layers_for_window` builds the Metal compositor's
    layers.
- **Prove the path is taken.** Before hooking a function, check that the window you care about
  reaches it. Kind-5 (CA-backed) windows never reach `MetalBacking::DetermineShaderOptions`, and
  that cost several rounds. Check the dispatch (`if (window->kind == 5)` and so on) and its
  callers.
- **Read the exact call site for ABI.** For C++ statics and vtable calls, copy the register and
  stack layout from a real caller's decompile. Remember the HFA rules: a `CGRect` goes in
  d0–d3, a `CGPoint` in d0–d1.
- **Write findings down.** Put them in `docs/` (or a sibling doc): function,
  offset, what reads it, and how you know. The next session starts from that file.

## Testing loop

- `scripts/deploy.sh [Target...]` builds the named example tweaks (default `DragShaderExample`;
  arm64 + arm64e), signs them and installs them, plus the framework, into
  `/private/var/ammonia/core/tweaks`.
- Ammonia only loads tweaks when WindowServer starts. The user restarts it themself with
  `sudo killall WindowServer`, which logs them out. Claude's shell can't sudo, so ask them to do
  it, then ask what they saw.
- Log with `os_log` and a `WXF` prefix. `scripts/deploy.sh --logs` streams it. For past logs use
  `log show --last 10m --process WindowServer | grep WXF`; a predicate on the whole store times
  out.
- Videos the user sends: pull frames with `ffmpeg` into the scratchpad, then find the motion
  frames by frame differencing before looking. macOS screen recording names contain U+202F
  before AM/PM, so glob for the file rather than typing its name.
- Never overwrite a dylib WindowServer has mapped. Write to a temp name and `mv` it into place
  (`deploy.sh` does this).

## Framework rules

- The drag-shader API stays shader-agnostic. The framework provides the stand-in window, the
  geometry, the timing and a block of developer floats. Effects (jello, trails, ripples) live only in
  a tweak and its `.metal`. Each feature gets its own example target named `<Feature>Example`
  (`DragShaderExample`).
- The framework is one shared dynamic library (install name under the tweaks folder), not linked
  statically into tweaks: several tweaks can use it at once, and it hooks WindowServer once. Keep
  global state safe for more than one client, and where two clients want the same thing (one
  drag shader per drag) say which wins.
- Hooks are installed in one place, `WindowServerFramework/api/WXFHooks.c`. A feature defines its
  replacement and original pointer (external linkage, `WXF<Feature>Hook_x` / `WXF<Feature>Orig_x`)
  and adds a row to the table under a group; nothing else calls `HookServer`. A group installs all
  or none of its hooks. Add a group in `WXFHooks-Private.h` for a feature that installs lazily.
- New source files credit `bedtime`. Older files credit Salty; leave those as they are.
- Reference sources are inputs to read, never to ship. `Vanish.c`, `Common.metal`,
  `Dissolve.metal` and `WaterSim.h` are gitignored. `SkyLightServer.h` is untracked, so don't
  commit it.
