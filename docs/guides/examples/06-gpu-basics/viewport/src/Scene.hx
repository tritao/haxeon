import haxeon.gpu.Renderer;
import haxeon.platform.FrameTick;
import haxeon.platform.GraphicsImageRef;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.ui.Color;
import haxeon.ui.GraphicsSurface;
import haxeon.ui.host.UiOverlay;
import haxeon.ui.widgets.GpuViewport;

/** The fountain's GPU work and the UI that shows it in a viewport beside its controls. */
class Scene {
	final renderer:Renderer;
	final fountain:Fountain;
	final picture:GraphicsImageRef;
	final content:GraphicsSurfaceViewportContent;
	final view:FountainView;

	public function new(surface:Surface) {
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

	/** Draws the fountain into its image, then the UI that composites it. */
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

	public function dispose():Void {
		picture.dispose();
		renderer.dispose();
	}
}
