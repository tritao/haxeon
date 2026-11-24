import haxeon.gpu.Buffer;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.Pipeline;
import haxeon.gpu.Renderer;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.App;
import haxeon.platform.FrameTick;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;

import shaders.Triangle;

class Main implements App {
	final surface:Surface;
	var renderer:Renderer;
	var commands:CommandBuffer;
	var open = true;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var window = runtime.createWindow(new WindowOptions(640, 480));
		window.onClose(() -> open = false);
		surface = window.createSurface(SurfaceOptions.forGpu(640, 480));
		runtime.drive(surface);
	}

	public function ready():Void {
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

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		scoped var batch = renderer.batch()
			.windowPass(tick.width, tick.height)
			.commands(commands)
			.seal();
		var step = batch.frameStep();
		defer step.dispose();
		frame.submit([step]);
	}

	public function afterFrame():Void {}

	public function shouldQuit():Bool
		return !open;

	public function dispose():Void
		if (renderer != null) renderer.dispose();
}
