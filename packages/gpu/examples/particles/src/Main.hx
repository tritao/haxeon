import haxe.io.Bytes;
import haxeon.gpu.Buffer;
import haxeon.gpu.BufferDesc;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.Enums;
import haxeon.gpu.Pipeline;
import haxeon.gpu.Renderer;
import haxeon.gpu.Shader;
import haxeon.gpu.SurfaceOptions;
import haxeon.gpu.VertexLayout;
import haxeon.platform.App;
import haxeon.platform.FrameTick;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;

import shaders.Particles;

class Main implements App {
	static inline var count = 8192;
	static inline var groupSize = 64;
	static inline var particleBytes = 16;

	final surface:Surface;
	final params = Bytes.alloc(Particles.stepParams.size);
	var renderer:Renderer;
	var step:Pipeline;
	var particles:Buffer;
	var simulate:CommandBuffer;
	var draw:CommandBuffer;
	var time = 0.0;
	var open = true;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var window = runtime.createWindow(new WindowOptions(640, 640));
		window.onClose(() -> open = false);
		surface = window.createSurface(SurfaceOptions.forGpu(640, 640));
		runtime.drive(surface);
	}

	public function ready():Void {
		renderer = Renderer.create(surface);
		if (!renderer.features().compute)
			throw "Particles needs compute shaders: OpenGL 4.3, Direct3D 11 or Metal";
		step = Pipeline.beginCompute(renderer, Shader.create(renderer, Particles.step)).compute().build();
		var points = Pipeline.begin(renderer, Shader.create(renderer, Particles.draw), VertexLayout.none).build();
		particles = Buffer.create(renderer, new BufferDesc(count * particleBytes, BufferUsage.Storage));
		simulate = renderer.commandBuffer(8);
		draw = renderer.commandBuffer(4);
		draw.applyPipeline(points);
		draw.applyStorageBuffer(0, particles);
		draw.draw(0, 6, count);
	}

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
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
			.commands(draw)
			.seal();
		var submit = batch.frameStep();
		defer submit.dispose();
		frame.submit([submit]);
	}

	public function afterFrame():Void {}

	public function shouldQuit():Bool
		return !open;

	public function dispose():Void
		if (renderer != null) renderer.dispose();
}
