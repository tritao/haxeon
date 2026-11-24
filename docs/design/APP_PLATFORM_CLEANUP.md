# App platform cleanup

Status: planned. Remaining work after the shared surface-frame queue,
`AppLoop` and `UiOverlay` landed. The goal is that a sample such as Circuit
Run (`packages/gpu/examples/circuit-run`) has no target conditionals and no
custom defines: what differs between desktop and web belongs to the
platform, UI and GPU packages.

Circuit Run's remaining target conditionals, and the step that
removes each:

| Site | Removed by |
| --- | --- |
| Static `app`/`loop`, exported `poll` and `shutdown` | 5 |
| Web font file passed to `UiOverlay.attach` | 4 |
| Desktop-only `window.onResize` → `surface.setBounds` | 3 |
| `maze-web.*.glsl` chosen in `CircuitRenderer` | 7 |

## 1. Frames that fail without breaking the surface

Implemented. NativeKit reports `NK_ERROR_SURFACE_LOST` for frames invalidated
by drawable loss. `AppLoop` retries skipped work and pauses acquisition from
surface loss until the next readiness event.

## 2. Tidy `AppLoop`

Implemented with step 1. Fields are grouped before methods.

## 3. Surfaces follow their window

Implemented. `SurfaceFlags.FillWindow` follows the window content area.
`SurfaceOptions.forGpu` enables it by default. Apps with manually placed
surfaces can clear the flag or create their own platform surface options.

## 4. Default fonts on every target

Implemented. `FontCollection.addDefaultFonts()` enables system fallback
discovery on desktop and installs IBM Plex Sans on web. The browser receives
the default font with the native UI Wasm module before app startup. Hosts and
overlays use the same API. The showcase still fetches its extra script and
emoji fonts before it starts.

## 5. One app loop: `Runtime.launch` under `UiHost.run`

Implemented. `Runtime.launch` owns the app and runtime and drains the last
submitted frame before teardown. Apps register a frame-driving surface with
`runtime.drive(surface)`; they can create additional windows. `UiHost.run`
uses the same loop, and live runners keep a cooperative session from
`UiHost.open`.

The SDK's WebGL2 host drives the platform tick export. Circuit Run and Audio
Lab build with `haxeon build --target wasm32` and share the SDK host,
including its audio exports. Desktop diagnostics still support bounded
captures and scripted input.

## 6. `ShowcaseWeb` on the same loop

Implemented. `ShowcaseWeb` runs through `UiHost.run`. The UI Explorer and
Graphics Lab use one window and one frame transaction. The Graphics Lab
seals a snapshot of its rotating cube with the display list. Visual tests
and benchmarks drive the same loop with explicit frame times.

## 7. Shaders through the shared toolchain

App shaders use NativeKit's shader toolchain
([NativeKit ADR 0021](../../vendor/nativekit/docs/decisions/0021-shader-toolchain.md)):
one GLSL source in `sokol-shdc` form, compiled at build time to `glsl410`,
`glsl300es`, `hlsl5` and Metal, with checked-in output and a `--check` mode.
The generated sources carry the `#version` and precision lines; the edited
source stays backend-neutral.

The shared NativeKit generator produces C tables and versioned reflection.
The UI uses the C tables and keeps its existing shader source header
byte-identical. CI checks regeneration for UI and Circuit Run.

Circuit Run declares the maze once in `maze.glsl`. Its generated Haxe
module selects the variant from the renderer's live backend. The remaining
Haxe shader interface work is tracked in `TODO.md`.

## Rejected

- **A `GL_ES` header block resolved by NativeKit** (`#ifdef GL_ES` choosing the
  `#version` line). It keeps both headers visible, but it is not valid GLSL for
  validators and editors, and covers only GL and GLES.
- **`#cfg` for the remaining conditionals.** It is a design in
  [FUTURE_LANGUAGE.md](FUTURE_LANGUAGE.md) §16, not implemented, and the sites
  above are library responsibilities whatever the condition syntax. Library
  branches that remain test the target (`#if wasm`), not custom defines, so
  they convert mechanically later.
