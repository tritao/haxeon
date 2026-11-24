import haxeon.gpu.Renderer;
import haxeon.gpu.SurfaceOptions;
import haxeon.platform.App;
import haxeon.platform.FrameTick;
import haxeon.platform.GraphicsImageRef;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.WindowOptions;
import haxeon.ui.Color;
import haxeon.ui.GraphicsSurface;
import haxeon.ui.core.GraphicsSurfaceViewportContent;
import haxeon.ui.host.UiOverlay;
import haxeon.ui.widgets.GpuViewport;
import nativekit.ffi.NativeKitTypes;

class Main implements App {
	final surface:Surface;
	final overlay:UiOverlay;
	var renderer:Renderer;
	var fountain:Fountain;
	var picture:GraphicsImageRef;
	var content:GraphicsSurfaceViewportContent;
	var view:FountainView;
	var open = true;

	public static function main():Void
		Runtime.launch(runtime -> new Main(runtime));

	function new(runtime:Runtime) {
		var options = new WindowOptions(960, 600);
		options.title = "Viewport";
		options.flags = WindowFlags.Resizable;
		var window = runtime.createWindow(options);
		window.onClose(() -> open = false);
		surface = window.createSurface(SurfaceOptions.forGpu(960, 600));
		overlay = UiOverlay.attach(window, surface, runtime.events);
		runtime.drive(surface);
	}

	public function ready():Void {
		renderer = Renderer.create(surface);
		if (!renderer.features().compute)
			throw "Viewport needs compute shaders: OpenGL 4.3, Direct3D 11 or Metal";
		fountain = new Fountain(renderer);
		picture = fountain.image.graphicsImage();
		content = new GraphicsSurfaceViewportContent(GraphicsSurface.fromImage(picture), Fountain.size, Fountain.size);
		var viewport = new GpuViewport("fountain", content).fitToView(0.0);
		viewport.setAppearance(Color.rgba(0.03, 0.04, 0.07, 1.0), Color.rgba(0, 0, 0, 0), 1.0, false);
		view = new FountainView(fountain, viewport);
	}

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		scoped var batch = fountain.record(tick.deltaSeconds);
		var gpu = batch.frameStep();
		defer gpu.dispose();
		content.invalidate();
		overlay.invalidate();
		var ui = overlay.frameStep(view, frame, tick);
		defer ui.dispose();
		frame.submit([gpu, ui]);
	}

	public function afterFrame():Void {}

	public function shouldQuit():Bool
		return !open;

	public function dispose():Void {
		overlay.dispose();
		if (picture != null) picture.dispose();
		if (renderer != null) renderer.dispose();
	}
}
