import haxeon.gpu.Buffer;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.GpuError;
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

	function new(renderer:Renderer, commands:CommandBuffer) {
		this.renderer = renderer;
		this.commands = commands;
	}

	/** The scene drawn to `surface`, or why the GPU cannot draw it. */
	public static function create(surface:Surface):Result<Scene, GpuError> {
		var renderer = try Renderer.create(surface);
		var shader = try Triangle.create(renderer);
		var pipeline = try Pipeline.begin(renderer, shader, Triangle.Vertex.layout).build();
		var vertices = Buffer.vertexFloats(renderer, [
			// x, y, r, g, b
			0.0, 0.6, 1.0, 0.4, 0.5,
			-0.6, -0.5, 0.3, 0.9, 0.6,
			0.6, -0.5, 0.4, 0.5, 1.0
		]);
		var commands = renderer.commandBuffer(4);
		commands.applyPipeline(pipeline);
		commands.applyVertexBuffer(0, vertices, 0);
		commands.draw(0, 3, 1);
		return Ok(new Scene(renderer, commands));
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
