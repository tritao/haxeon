# Particles

A fountain of 8,192 particles simulated on the GPU. Each frame a compute
shader moves every particle in a storage buffer, launching new ones from
the spout, and a draw reads the same buffer from its vertex shader to place
a small quad per particle. Nothing goes back to the CPU.

`src/shaders/Particles.glsl` holds both programs, `step` and `draw`, and
the struct they share. The build compiles the file for each backend and
generates the `shaders.Particles` module. See
[Writing shaders](../../../../docs/reference/WRITING_SHADERS.md#compute-shaders).

It needs compute shaders: OpenGL 4.3, Direct3D 11 or Metal. From the
repository root on Linux with an X11 display:

```sh
scripts/haxeon run --project packages/gpu/examples/particles/haxeon.json
```
