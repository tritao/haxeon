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
vertex layout to create a pipeline.

```haxe
import haxeon.gpu.Pipeline;
import shaders.Quad;

var shader = Quad.create(renderer);
var pipeline = Pipeline.begin(renderer, shader, Quad.Vertex.layout).build();
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
On first use in a source checkout, the driver downloads the pinned compiler
with `curl` if it cannot reuse a verified cached copy. NativeKit’s CI validates
the generated GLSL for its shader fixtures. App builds skip that validation.

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
when several shader modules are imported together. Programs and variants in
the same module share its vertex layout.
