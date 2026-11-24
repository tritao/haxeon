# Triangle

The smallest GPU app: one window, one shader and one draw. `ready()` creates
the renderer, the pipeline and a vertex buffer, and records the draw once.
`frame()` seals that draw into a window pass and submits it.

The shader is `src/shaders/Triangle.glsl`, written once in the sokol-shdc
dialect. The build compiles it for the backend and generates the
`shaders.Triangle` module, whose `Vertex.layout` describes the buffer's
position and colour.

From the repository root on Linux with an X11 display and OpenGL 4.1:

```sh
scripts/haxeon run --project packages/gpu/examples/triangle/haxeon.json
```

See [Writing shaders](../../../../docs/reference/WRITING_SHADERS.md) for the
shader dialect and the generated module.
