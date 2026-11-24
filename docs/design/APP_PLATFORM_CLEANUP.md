# App platform cleanup

Status: planned. Remaining work after the shared surface-frame queue,
`AppLoop` and `UiOverlay` landed. The goal is that a sample such as Circuit
Run (`packages/gpu/examples/circuit-run`) has no target conditionals and no
custom defines: what differs between desktop and web belongs to the
platform, UI and GPU packages.

Circuit Run's remaining `#if circuit_run_web` sites, and the step that
removes each:

| Site | Removed by |
| --- | --- |
| Static `app`/`loop`, exported `poll` and `shutdown` | 5 |
| Web font file passed to `UiOverlay.attach` | 4 |
| Desktop-only `window.onResize` → `surface.setBounds` | 3 |
| `maze-web.*.glsl` chosen in `CircuitRenderer` | 7 |

## 1. Frames that fail without breaking the surface

`AppLoop` skips frames completed with `ErrorCancelled`. Two gaps remain:

- NativeKit reports `NK_ERROR_CANCELLED` only when queued render work is
  dropped without running. A surface lost to a minimize, resize or context
  loss fails the frame's bind or a step with another result, and the app
  stops. Give that case one result (for example `NK_ERROR_SURFACE_LOST`) that
  `AppLoop` also skips, and test it with a real surface loss.
- A skipped frame is not requested again. An on-demand app whose overlay
  already cleared its dirty state keeps a stale picture until something else
  requests a frame. `AppLoop` requests a new frame after a skip.

## 2. Tidy `AppLoop`

Group its fields before its methods; `firstFramePresented` and `stop()` are
interleaved with the field declarations.

## 3. Surfaces follow their window

Add `NK_SURFACE_FILL_WINDOW` (`SurfaceFlags.FillWindow`): the backend keeps the
surface bounds equal to the window's content area, as the web canvas already
does. `SurfaceOptions.forGpu` sets it by default; apps that place surfaces
themselves leave it off.

## 4. Default fonts on every target

`UiHost` already defaults browser fonts to the SDK's IBM Plex Sans
(`BrowserUiHost`, `UiHostOptions.fonts`, `UiFontAsset`), fetched as resources
before the app starts. `FontCollection` and `UiOverlay` have no such default,
which is why Circuit Run loads its own font file.

- Move the SDK font list and its loading out of `BrowserUiHost` into one place
  in the UI package that every host and `UiOverlay` use.
- Rename `FontCollection.addSystemFallbacks()` to `addDefaultFonts()`, with no
  alias: system fonts on desktop, the SDK fonts on web (browsers do not expose
  system font bytes without a permission prompt).
- On web the fonts arrive asynchronously, so the app loop loads them before the
  app's `ready`, as `BrowserUiHost` does now. One loading path replaces the
  `nativekit_bundle_web_fonts` split.

## 5. One app loop: `Runtime.launch` under `UiHost.run`

There are now two entry systems: the platform's `Runtime.startApp` and
`AppLoop` (Circuit Run, `Triangle`), and the UI's `UiHost.run` with
`UiApplication` (the app template and guides), each with its own
`#if wasm` session and tick export. They become one loop.

```haxe
static function main()
    Runtime.launch(runtime -> new Main(runtime));
```

- `App` extends `Disposable`. It does not expose a single surface, so
  multi-window apps fit; the app tells the loop which surface drives frames
  once it has created it.
- Desktop: `launch` runs the loop, then disposes the app and the runtime under
  the first-exception rule.
- Wasm: `launch` registers the loop and returns. One platform-owned export
  advances it and returns a typed status; once the loop stops and its pending
  frame completes, it disposes the app and the runtime.
- `UiHost.run` becomes a `Runtime.launch` of an app that hosts a
  `UiApplication`. Its `start`/`tick`/`close` statics and integer statuses go,
  and its string throws (`Std.string(error)`, "UI host options are invalid")
  become typed errors.
- `haxeon build --target wasm32` already turns a template app into a page with
  the SDK's WebGL2 host. Every web app uses it: Circuit Run and audio-lab drop
  their `build-guest.sh`, `exports.js` and polling `index.html`, and
  `--define=circuit_run_web` goes.

## 6. `ShowcaseWeb` on the same loop

Replace its static fields with a `UiApplication` run through `UiHost.run`, and
delete the old entry style.

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
