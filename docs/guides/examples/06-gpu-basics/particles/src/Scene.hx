import haxe.io.Bytes;
import haxeon.gpu.Buffer;
import haxeon.gpu.BufferDesc;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.Enums;
import haxeon.gpu.Pipeline;
import haxeon.gpu.Renderer;
import haxeon.gpu.Shader;
import haxeon.gpu.VertexLayout;
import haxeon.platform.FrameTick;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;

import shaders.Particles;

/** A fountain of particles: a compute step moves them, and a draw reads the same storage buffer. */
class Scene {
	static inline var count = 8192;
	static inline var groupSize = 64;
	static inline var particleBytes = 16;

	final renderer:Renderer;
	final step:Pipeline;
	final particles:Buffer;
	final simulate:CommandBuffer;
	final render:CommandBuffer;
	final params = Bytes.alloc(Particles.stepParams.size);
	var time = 0.0;

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
		var submit = batch.frameStep();
		defer submit.dispose();
		frame.submit([submit]);
	}

	public function dispose():Void
		renderer.dispose();
}
