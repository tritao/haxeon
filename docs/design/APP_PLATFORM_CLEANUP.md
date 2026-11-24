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

What exists: the UI package's `tools/generate-shaders.py` runs `sokol-shdc`
over `packages/ui/shaders` and checks in a C header, with
`tools/check-shaders.sh`. `sokol-shdc` is not pinned or fetched, and no CI job
runs the check.

Needed, in order:

1. ADR 0021's first migration step: the shared tool in `modules/gpu/tools`
   with a pinned `sokol-shdc`, the manifest, `nkgpu_shader_create_from_table()`
   and the `nkgpu-shader-reflection/1` JSON. The UI shaders move to it with
   byte-identical output, and CI runs `--check`.
2. The Haxeon generator from that JSON (see the shader-interface item in
   `TODO.md`): typed uniform records, a descriptor per program, creation by
   program ID.
3. The GPU package creates a program for the renderer's live backend, so app
   code does not pass a shader language.
4. Circuit Run's maze becomes one program; `maze-web.*.glsl` and the
   conditional in `CircuitRenderer` are deleted.

Until then Circuit Run keeps its two GLSL files. First check which GPU backend
Windows and macOS use for it: if D3D11 or Metal, its GLSL-only shaders do not
run there today.

## Rejected

- **A `GL_ES` header block resolved by NativeKit** (`#ifdef GL_ES` choosing the
  `#version` line). It keeps both headers visible, but it is not valid GLSL for
  validators and editors, and covers only GL and GLES.
- **`#cfg` for the remaining conditionals.** It is a design in
  [FUTURE_LANGUAGE.md](FUTURE_LANGUAGE.md) §16, not implemented, and the sites
  above are library responsibilities whatever the condition syntax. Library
  branches that remain test the target (`#if wasm`), not custom defines, so
  they convert mechanically later.
