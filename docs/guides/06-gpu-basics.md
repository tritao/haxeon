# GPU basics

In this guide you draw with the `gpu` package: first a triangle, then a fountain of particles that a compute shader moves,
and last that fountain inside a UI layout beside the controls that steer it. Along the way you meet windows and surfaces,
shaders written once in GLSL, pipelines, buffers, command buffers and batches.

The finished projects are in [examples/06-gpu-basics](examples/06-gpu-basics/): `triangle`, `particles` and `viewport`,
without their runners (`linux/`, `macos/`, `windows/`), which `haxeon create .` adds. They build and run on Linux, macOS
and Windows. The particles and the viewport need compute shaders: OpenGL 4.3, Direct3D 11 or Metal.

## Start a project

Create an app and change its dependency from the UI package to the GPU package:

```sh
haxeon create triangle --org org.example
cd triangle
```

```toml
[dependencies]
gpu = "^0.3"
```

The template's `src/Main.hx` is a UI app. In this guide `src/Main.hx` opens a window and hands each frame to a `Scene`,
which owns the GPU work, so replace it.

## Open a window and a surface

An app implements `App`. `Runtime.launch` creates it and drives its frames from a surface, the part of a window the GPU
draws into:

```haxe
class Main implements App {
	final surface:Surface;
	var scene:Null<Scene> = null;
	var open = true;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var window = runtime.createWindow(new WindowOptions(640, 480));
		window.onClose(() -> open = false);
		surface = window.createSurface(SurfaceOptions.forGpu(640, 480));
		runtime.drive(surface);
	}

	public function ready():Void
		scene = new Scene(surface);

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		var scene = this.scene;
		if (scene != null) scene.draw(tick, frame);
	}
```

`ready` runs once, when the surface can render; that is when the GPU resources can be made, so the `Scene` is created
there. `frame` then runs for every frame the surface draws. `shouldQuit` returns `true` once the window closes, and
`dispose` releases the scene.

## Write the shader

A shader is one GLSL file under `src/shaders/`, with a vertex stage, a fragment stage and a program that joins them.
`src/shaders/Triangle.glsl`:

```glsl
@vs triangle_vs
layout(location=0) in vec2 position;
layout(location=1) in vec3 rgb;
out vec3 color;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    color = rgb;
}
@end

@fs triangle_fs
in vec3 color;
out vec4 pixel;

void main() {
    pixel = vec4(color, 1.0);
}
@end

@program triangle triangle_vs triangle_fs
```

Before Haxe compiles, the build compiles this file for the platform's graphics API and generates the module
`shaders.Triangle`. `Triangle.create` makes the shader, and `Triangle.Vertex` describes its vertex input: the stride, an
offset for each attribute, and the `layout` a pipeline takes. [Writing shaders](../reference/WRITING_SHADERS.md) covers
the dialect, uniforms, includes and variants.

## Set up once

`Scene`'s constructor makes everything the frames reuse:

```haxe
public function new(surface:Surface) {
	renderer = Renderer.create(surface);
	var shader = Triangle.create(renderer);
	var pipeline = Pipeline.begin(renderer, shader, Triangle.Vertex.layout).build();
	var vertices = Buffer.vertexFloats(renderer, [
		// x, y, r, g, b
		0.0, 0.6, 1.0, 0.4, 0.5,
		-0.6, -0.5, 0.3, 0.9, 0.6,
		0.6, -0.5, 0.4, 0.5, 1.0
	]);
	commands = renderer.commandBuffer(4);
	commands.applyPipeline(pipeline);
	commands.applyVertexBuffer(0, vertices, 0);
	commands.draw(0, 3, 1);
}
```

The `Renderer` belongs to the surface. A `Pipeline` combines the shader with its vertex layout and render state. The
vertex buffer holds three vertices of five floats each, in the order `Triangle.Vertex` gives: a position and a colour.

A `CommandBuffer` records GPU commands to replay later. The triangle never changes, so its draw is recorded here, once.

## Draw each frame

```haxe
public function draw(tick:FrameTick, frame:SurfaceFrame):Void {
	scoped var batch = renderer.batch()
		.windowPass(tick.width, tick.height)
		.commands(commands)
		.seal();
	var step = batch.frameStep();
	defer step.dispose();
	frame.submit([step]);
}
```

A `Batch` lists passes and the commands to run in each. This one has a single pass that clears the window and draws the
triangle. `seal` freezes it, `frameStep` turns it into a step of this frame, and `frame.submit` hands the frame's steps
to the surface, which presents them. `scoped` and `defer` release the batch and the step when `draw` returns.

## Run it

```sh
haxeon create .
haxeon run
```

`haxeon create .` adds the runners, keeping your code. The window shows a triangle shaded from pink at the top to green
and blue at its lower corners.

The surface draws continuously. An app that changes only on input can call
`surface.setFrameMode(SurfaceFrameMode.OnDemand)` and then `surface.requestFrame()` whenever it needs to draw again.

## Compute: a particle fountain

The `particles` project moves 8,192 particles on the GPU. Each frame a compute shader updates them in a storage buffer,
and a draw reads the same buffer, so nothing goes back to the CPU.

Both programs live in `src/shaders/Particles.glsl`. A `@block` holds the struct they share, and a compute stage moves
each particle:

```glsl
@block particle
struct particle {
    vec2 position;
    vec2 velocity;
};
@end

@cs step_cs
@include_block particle
@include_block launch
layout(local_size_x=64) in;

layout(binding=0) buffer particles {
    particle items[];
};

layout(std140, binding=0) uniform step_params {
    float dt;
    float time;
};

void main() {
    uint index = gl_GlobalInvocationID.x;
    particle p = items[index];
    float seed = float(index) * 0.618 + time;
    // The buffer starts zeroed: spread the first launches along the arc.
    if (p.velocity == vec2(0.0)) {
        p = launch(seed, 2.4 * hash(float(index)));
    } else if (p.position.y < -1.0) {
        p = launch(seed, 0.0);
    }
    p.velocity.y -= gravity * dt;
    p.position += p.velocity * dt;
    items[index] = p;
}
@end
```

The `launch` block puts a particle on its arc from the spout. The draw program's vertex stage reads `items[gl_InstanceIndex]`
from the same buffer and places a small quad per particle. A file with a compute stage compiles for GLSL 4.3 on OpenGL,
which has compute and storage buffers, and the generated `shaders.Particles` exposes each program by name.

`Scene` makes a compute pipeline for the step and a graphics pipeline for the draw. The draw takes no vertex buffer, so
its layout is `VertexLayout.none`, and its commands are recorded once:

```haxe
public function new(surface:Surface) {
	renderer = Renderer.create(surface);
	if (!renderer.features().compute)
		throw "Particles needs compute shaders: OpenGL 4.3, Direct3D 11 or Metal";
	step = Pipeline.beginCompute(renderer, Shader.create(renderer, Particles.step)).compute().build();
	var points = Pipeline.begin(renderer, Shader.create(renderer, Particles.draw), VertexLayout.none).build();
	particles = Buffer.create(renderer, new BufferDesc(count * particleBytes, BufferUsage.Storage));
	simulate = renderer.commandBuffer(8);
	render = renderer.commandBuffer(4);
	render.applyPipeline(points);
	render.applyStorageBuffer(0, particles);
	render.draw(0, 6, count);
}
```

`features()` says what the renderer supports; WebGL2 and OpenGL drivers older than 4.3 have no compute. Each frame
records the step with this frame's uniforms and runs it in a compute pass before the window pass:

```haxe
public function draw(tick:FrameTick, frame:SurfaceFrame):Void {
	var dt = Math.min(tick.deltaSeconds, 1.0 / 30.0);
	time += dt;
	params.setFloat(0, dt);
	params.setFloat(4, time);
	simulate.reset();
	simulate.applyPipeline(step);
	simulate.applyStorageBuffer(0, particles);
	simulate.applyUniforms(Particles.stepParams.slot, params);
	simulate.dispatch(Std.int(count / groupSize));
	scoped var batch = renderer.batch()
		.computePass()
		.commands(simulate)
		.windowPass(tick.width, tick.height)
		.commands(render)
		.seal();
```

`Particles.stepParams` is the generated description of the `step_params` block: its slot and its size, which `params`
was allocated with. `dispatch` runs one group of 64 invocations per 64 particles, matching `local_size_x`.

## GPU drawing inside a UI

The `viewport` project shows the fountain in a UI layout: a sidebar with sliders, a switch and a button, beside a
`GpuViewport`. It depends on both packages:

```toml
[dependencies]
gpu = "^0.3"
ui = "^0.3"
```

`Fountain` draws the particles into an offscreen image instead of the window, with a render pass whose colour attachment
is that image. `Scene` hands the image to the UI:

```haxe
fountain = new Fountain(renderer);
picture = fountain.image.graphicsImage();
content = new GraphicsSurfaceViewportContent(GraphicsSurface.fromImage(picture), Fountain.size, Fountain.size);
var viewport = new GpuViewport("fountain", content).fitToView(0.0);
```

A `GpuViewport` is a view like any other: it composites the image, `fitToView` keeps it fitted to the space the layout
gives it, and it pans on drag and zooms on scroll. `FountainView` lays it out beside the controls, whose callbacks change
the fountain's settings:

```haxe
var row = new Row("root", [
	new KeyedView("controls", controls),
	new KeyedView("viewport", viewport)
], rootStyle());
```

A `UiOverlay` draws the UI on the window's surface. Each frame submits the GPU work first, then the UI that composites
its result:

```haxe
public function draw(tick:FrameTick, frame:SurfaceFrame, overlay:UiOverlay):Void {
	scoped var batch = fountain.record(tick.deltaSeconds);
	var gpu = batch.frameStep();
	defer gpu.dispose();
	content.invalidate();
	overlay.invalidate();
	var ui = overlay.frameStep(view, frame, tick);
	defer ui.dispose();
	frame.submit([gpu, ui]);
}
```

`content.invalidate()` tells the viewport its image changed, and `overlay.invalidate()` asks the UI to draw again.

## Next

- [Writing shaders](../reference/WRITING_SHADERS.md): uniforms, textures, includes, variants and compute.
- [Calling a C or C++ library](04-calling-c-and-cpp.md), for a renderer you already have in C or C++.
- [UI basics](03-ui-basics.md), for the controls around a viewport.
- [Circuit Run](https://github.com/tritao/haxeon/tree/main/packages/gpu/examples/circuit-run): a small game that draws
  its maze in one GPU draw per frame, with UI controls over it.
