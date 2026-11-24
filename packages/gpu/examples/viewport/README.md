# Viewport

GPU drawing inside a UI layout. The window is a Haxeon UI: a sidebar of
controls beside a `GpuViewport`. The app runs a compute particle fountain
and draws it into an offscreen image each frame. The viewport composites
that image, keeps it fitted to the space the layout gives it, and pans on
drag and zooms on scroll. Moving the sliders, the toggle or the button
changes the fountain's uniforms on the next frame.

- `FountainView.hx` builds the layout.
- `Fountain.hx` owns the GPU work: the compute step and the offscreen pass.
- `Main.hx` runs the frame loop and submits the GPU batch before the UI.

It needs compute shaders: OpenGL 4.3, Direct3D 11 or Metal. From the
repository root on Linux with an X11 display:

```sh
scripts/haxeon run --project packages/gpu/examples/viewport/haxeon.json
```
