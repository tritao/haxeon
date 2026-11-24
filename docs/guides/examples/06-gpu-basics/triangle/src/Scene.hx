import haxeon.gpu.Buffer;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.Pipeline;
import haxeon.gpu.Renderer;
import haxeon.platform.FrameTick;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;

import shaders.Triangle;

/** The GPU resources, created once the surface is ready, and the draw each frame. */
class Scene {
	final renderer:Renderer;
	final commands:CommandBuffer;

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

	public function draw(tick:FrameTick, frame:SurfaceFrame):Void {
		scoped var batch = renderer.batch()
			.windowPass(tick.width, tick.height)
			.commands(commands)
			.seal();
		var step = batch.frameStep();
		defer step.dispose();
		frame.submit([step]);
	}

	public function dispose():Void
		renderer.dispose();
}
