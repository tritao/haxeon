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
one GLSL source in `sokol-shdc` form, compiled to `glsl410`, `glsl300es`,
`hlsl5` and Metal. The edited source stays backend-neutral; the generated
sources carry the `#version` and precision lines.

### Where it stands

NativeKit generates normalized reflection and C tables. The UI uses the tables
and keeps its original shader source header byte-identical.
`Shader.create(renderer, program)` passes the table through HXI, and NativeKit
selects the target. Haxe also gets checked native uniform layouts with
module-prefixed record names so shaders can reuse names such as `vs_params`.

Circuit Run has one authored shader and imports `shaders.Maze` from the build.
The project build and watch loop use the same per-target generator and cache.
See [Writing shaders](../reference/WRITING_SHADERS.md) for paths and examples.

### End state

The author writes one file and imports it:

```
src/shaders/Maze.glsl      // @vs / @fs / @program; no #version, no target branches
```

```haxe
import shaders.Maze;

var shader = Maze.create(renderer);
var pipeline = Pipeline.begin(renderer, shader, Maze.Vertex.layout)...
batch.uniforms(Maze.vsParams, {mvp: matrix});
```

- **No manifest and no generated files in the app.** `.glsl` files under the
  project's shader root are discovered. Variants, which are rare, are
  declared in `haxeon.json`.
- **The build runs it.** `haxeon build`, `check` and `run --watch` compile shaders
  before typing: the SDK's pinned `sokol-shdc`, NativeKit's normalization to
  `nkgpu-shader-reflection/1`, then the Haxe generator, writing to a build
  source root. Results are cached by the content of the source and its
  includes and the compiler checksum; the build server redoes only changed
  shaders.
- **One source of truth.** Reflection gives the program descriptor, the
  vertex layout (no hand-written stride or attribute formats) and uniform
  records with std140 layout. An interface change breaks the Haxe that uses
  it at compile time.
- **Variant choice in one place.** `Maze.create` hands the program table to
  `nkgpu_shader_create_from_table`; Haxe does not switch on the backend. A
  target embeds only its backends: glsl300es on Wasm and Android, glsl410 on
  Linux, hlsl5 on Windows, Metal on Apple platforms.
- **Diagnostics in the author's source.** `sokol-shdc` errors become
  `Maze.glsl:12: ...` in Haxeon's diagnostic format, and common dialect
  mistakes (a `#version` line, a uniform outside a block) get a message that
  states the rule.

For people and agents alike, the generated API has to be readable without
running anything clever:

- **Fixed names.** `Maze.glsl` is module `shaders.Maze`; each `@program` is a
  field; uniform block `vs_params` is record `VsParams` and field
  `vsParams`; attributes form `Maze.Vertex`.
- **A stable, documented output path** for the generated modules, plus IDE
  hover, so the API can be read and searched.
- **One canonical example**: a "Writing shaders" guide with a full shader
  (attributes, a uniform block, a texture) and the Haxe that uses it, and a
  shader in the app template. Authors copy the nearest example.

### Ownership

- **NativeKit owns the driver**: running the pinned compiler, walking
  includes, normalized JSON, C tables, `--check`. It is one implementation for
  C and Haxeon consumers. It becomes a native tool shipped in the SDK, so app
  authors need no Python; offering `sokol-shdc` a `bare_json` output upstream
  removes its YAML parsing.
- **Haxeon owns the build step and the generator**: JSON in, typed module out.
- **C consumers keep checked-in output** (UIKit, SceneKit): their CMake builds
  must not need the tool. Haxeon projects generate at build time because the
  SDK always carries it.
- **`sokol-shdc` stays unforked.** The SDK ships or fetches the pinned
  upstream binary, verified by SHA-256 per host. A missing reflection field
  is a small generic patch offered upstream. Only if upstream refuses a change
  we need do we carry that patch on the pinned commit and build `sokol-shdc`
  in CI.

### Implementation order

1. **NativeKit driver.** The reflection becomes a NativeKit-defined schema
   (attributes with format and HLSL semantic, uniform blocks with std140
   offsets, images with sample type, samplers), not `sokol-shdc`'s YAML keys
   passed through. Table entries name one `nkgpu_shader_target`
   (`GLSL410`, `GLSL300ES`, `HLSL5`, `METAL_MACOS`, `METAL_IOS`) instead of
   backend, language and a `metal_ios` flag. Pin `sokol-shdc` and
   `glslangValidator` by SHA-256. Record the distribution and no-fork policy
   above in ADR 0021.
2. **Haxe creation through the C table.** `Shader.create(renderer, program)`
   calls `nkgpu_shader_create_from_table`; add struct-array passing to the
   bindings if they lack it. The generated `switch` goes, and so does the
   public `Renderer.backend()` returning the FFI enum.
3. **Generator output.** Uniform records with `@:repr("C")` and compile-time
   `sizeof`/`offsetof` checks, `Vertex.layout` from the attributes, the fixed
   names above. Tested against the UI reflection, since the maze has no
   uniforms.
4. **Build integration.** Shader discovery, the cached build step, per-target
   embedding, diagnostics mapping, the generated source root.
5. **Circuit Run on it.** `Maze.glsl` and an import; delete `MazeShader.hx`,
   `maze.reflection.json`, `maze.shader.h`, `shaders.json` and the Circuit Run
   lines in `packages/gpu/tools/check-shaders.sh`. Run it on Windows and macOS
   (D3D11 and Metal), which its GLSL-only shaders never supported.
6. **Docs.** The "Writing shaders" guide and the template shader.
7. **Later.** The native driver binary in the SDK, `bare_json` upstream,
   shader hot reload in `haxeon dev`, precompiled DXBC and metallib once
   Windows and macOS CI hosts exist.

## Rejected

- **A `GL_ES` header block resolved by NativeKit** (`#ifdef GL_ES` choosing the
  `#version` line). It keeps both headers visible, but it is not valid GLSL for
  validators and editors, and covers only GL and GLES.
- **`#cfg` for the remaining conditionals.** It is a design in
  [FUTURE_LANGUAGE.md](FUTURE_LANGUAGE.md) §16, not implemented, and the sites
  above are library responsibilities whatever the condition syntax. Library
  branches that remain test the target (`#if wasm`), not custom defines, so
  they convert mechanically later.
