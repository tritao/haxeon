# Haxeon gpu package

This package owns NativeKit's Haxeon GPU API bindings and managed wrappers. NativeKit owns the public C headers, native implementation, and native tests.

Managed APIs live in `haxeon.gpu.*`. Generated HXI and projection maps live in `bindings/`; managed code lives in `src/`.

## Native dependency

The `vendor/nativekit` submodule pins the supported NativeKit revision. Initialize it and its native dependencies from the Haxeon repository root with `git submodule update --init --recursive vendor/nativekit`. Set `NATIVEKIT_DIR=/path/to/nativekit` to use a separate checkout. `HAXEON_DIR` may override the compiler checkout. Native libraries must be built and available on the runtime library search path; the package manifest does not build or bundle them.

## Tooling

Run tools from this package's `tools/` directory. Platform `tools/test-haxe-bindings.sh` performs ABI32/ABI64 checks and both platform and GPU runtime smoke tests. GPU `tools/update-haxeon-hxi.sh` regenerates its reviewed interface and `--check` verifies it without writing; `tools/test-haxeon.sh` runs the graphical stress fixture.

Generator source labels retain their original paths to preserve reviewed HXI content during extraction.

## Frame callbacks

Create a platform surface with `window.createSurface(SurfaceOptions.forGpu(width, height))`
and pass it to `Renderer.create(surface)`.

`haxeon.platform.Surface.onFrameTick` delivers a `FrameTick` with monotonic callback time and
framebuffer dimensions in pixels. Registering a new handler replaces the
previous one. Dispose the returned subscription to stop delivery early. Surface
disposal also detaches the handler.

Continuous callbacks are the default. For on-demand rendering, call
`surface.setFrameMode(SurfaceFrameMode.OnDemand)` and use
`surface.requestFrame()` whenever the surface needs a redraw.
`SurfaceFrameMode` is available from `nativekit.ffi.NativeKitTypes`.

Use `Renderer.withFrame(draw)` to begin and end a frame around draw commands.
It tries to abort an interrupted frame before rethrowing the original error.
Call `Renderer.abortFrame()` for recovery when managing frame boundaries directly.

For diagnostics, call `surface.captureFrameTiming(tick.timeSeconds)` inside the
callback and `markSubmitted()` after submission. Query `presentationSeconds()`
on a subsequent callback using the same timing object. GTK can report display
feedback. The timestamp is optional because feedback may still be pending or
unavailable on the current backend.

## Examples

[Circuit Run](examples/circuit-run/) is a Linux and WebGL2 maze-chase sample
that submits a GPU maze and a retained UI HUD to one platform surface.

## License

The extracted NativeKit bindings and wrappers retain their Apache License 2.0 license; see `LICENSE`.
