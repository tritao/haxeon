# Writing shaders

Put a GLSL shader under a project source root's `shaders/` directory, for
example `src/shaders/Quad.glsl`. Use an uppercase filename for the Haxe
module. Subdirectories become packages. Dependency packages can provide
shader modules the same way. Use distinct module paths across packages,
for example `shaders/lighting/Quad.glsl` for a lighting library. Files without an `@program` are
available to `@include` and are excluded from module discovery.

Use the sokol-shdc dialect. Start stages with `@vs` and `@fs`, end them
with `@end`, and join them with `@program`. The tool sets `#version`.
Declare numeric uniforms in a `layout(std140, binding=N) uniform` block,
and declare textures and samplers separately with explicit bindings.

The app template carries this optional example at `shaders/Quad.glsl`.
Move it to `src/shaders/Quad.glsl` to compile it.

```glsl
@vs quad_vs
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv;
layout(std140, binding=0) uniform vs_params {
    mat4 transform;
};
out vec2 texcoord;

void main() {
    gl_Position = transform * vec4(position, 0.0, 1.0);
    texcoord = uv;
}
@end

@fs quad_fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
in vec2 texcoord;
layout(location=0) out vec4 color;

void main() {
    color = texture(sampler2D(tex, smp), texcoord);
#ifdef PREVIEW
    color.rgb *= 0.5;
#endif
}
@end

@program quad quad_vs quad_fs
```

Give the project a dependency on `haxeon-gpu`, then use the reflected
vertex layout to create a pipeline. Creating the shader and the pipeline
returns a `Result` whose `Err` is a `GpuError`: `Unsupported` when the
program has no source for the renderer's backend.

```haxe
import haxeon.gpu.GpuError;
import haxeon.gpu.Pipeline;
import shaders.Quad;

function quadPipeline(renderer:Renderer):Result<Pipeline, GpuError> {
	var shader = try Quad.create(renderer);
	return Pipeline.begin(renderer, shader, Quad.Vertex.layout).build();
}
```

Use `Quad.Vertex` for offsets and stride when writing vertices. The
generated `Quad.vsParams` gives the uniform block's slot, stage, and byte
size. The generated C-layout record documents its checked std140 offsets.
Bind the reflected texture and sampler slots with the command buffer.

`haxeon build` and `haxeon check` generate the modules before Haxe is typed.
`haxeon run --watch` rebuilds the shader when it or one of its includes
changes. The generated sources are under
`build/<target>/generated/shaders/`, with `host` for the current desktop
target, and follow a configured `outputDir`. The language server can read
them after a build or check. Leave the generated directory out of version
control.

Generation reuses each unchanged module. The cache covers its source,
transitive includes, variant settings, and the verified shader compiler.
Only the active target's compiled shader source reaches the Haxe module.
Released SDKs include NativeKit’s shader driver and the pinned shader compiler.

For source-defined variants, add define sets keyed by Haxe module in
`haxeon.json`:

```json
{
  "shaderVariants": {
    "shaders.Quad": {
      "default": [],
      "preview": ["PREVIEW"]
    }
  }
}
```

The generated module declares a typed enum for the variants, named after the
module: `QuadVariant` for the example above. `import shaders.Quad;` brings it
into scope, and the variant is an argument of `Quad.create`:

```haxe
var shader = Quad.create(renderer, QuadVariant.Preview);
```

A module with several programs declares one enum per program that has
variants, named after the module and the program: program `quad` in
`Effects.glsl` takes `EffectsQuadVariant`. The prefix keeps the names distinct
when several shader modules are imported together. Graphics programs and
variants in the same module share its vertex layout.

## Compute shaders

A compute program has one `@cs` stage and declares its threadgroup size
with `layout(local_size_x=N) in;`. Storage buffers hold a flexible array
of a struct. Put shared structs in a `@block` and include it in each stage
that reads them:

```glsl
@block particle
struct particle {
    vec2 position;
    vec2 velocity;
};
@end

@cs step_cs
@include_block particle
layout(local_size_x=64) in;
layout(binding=0) buffer particles { particle items[]; };

void main() {
    uint index = gl_GlobalInvocationID.x;
    items[index].position += items[index].velocity * 0.016;
}
@end

@program step step_cs
```

A file with a compute stage compiles for GLSL 4.3 on desktop OpenGL and
GLSL ES 3.1 on GLES, since earlier versions have no compute or storage
buffers. Graphics programs in the same file compile for those versions
too, so their vertex shaders can read the same storage buffers. Check
`renderer.features().compute` before creating compute pipelines: WebGL2
and OpenGL drivers older than 4.3 have none.

A module with several programs exposes each one by name. Create the
compute pipeline from `Shader.create(renderer, Particles.step)` with
`Pipeline.beginCompute`. A graphics program that reads only storage
buffers uses `VertexLayout.none`. Bind storage buffers with
`CommandBuffer.applyStorageBuffer` and record `dispatch` in a batch's
`computePass()`. [GPU basics](../guides/06-gpu-basics.md#compute-a-particle-fountain) runs
a compute step and draws the result each frame.
