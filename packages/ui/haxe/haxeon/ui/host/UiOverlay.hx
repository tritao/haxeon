package haxeon.ui.host;

import haxeon.platform.BindingError;
import haxeon.platform.DisposalRegistration;
import haxeon.platform.FrameTick;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.SurfaceFrameStep;
import haxeon.platform.Window;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import haxeon.ui.FontCollection;
import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.Renderer;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;

/** Retains a view between draws into a surface frame owned by the application. */
class UiOverlay implements Disposable {
	final surface:Surface;
	final logicalWidth:Float;
	final layout:LayoutFrame;
	final frameInfo:FrameInfo;
	final fonts:FontCollection;
	var renderer:Renderer;
	var context:UiContext;
	var binding:UiSurfaceBinding;
	var resizeSubscription:EventSubscription;
	var owner:DisposalRegistration;
	var lastView:View;
	var lastWidth = 0;
	var lastHeight = 0;
	var dirty = true;
	var disposed = false;

	/** Borrows the window and surface. Takes ownership of the supplied fonts. */
	public static function attach(window:Window, surface:Surface, events:EventPump, logicalWidth:Float,
			?fonts:FontCollection):UiOverlay {
		if (!Math.isFinite(logicalWidth) || logicalWidth <= 0.0)
			throw BindingError.invalidArgument("UiOverlay.attach", "The overlay's logical width must be positive and finite");
		var overlay = new UiOverlay(surface, logicalWidth, fonts == null ? FontCollection.create() : fonts);
		var attached = false;
		defer if (!attached) overlay.dispose();
		if (fonts == null) overlay.fonts.addSystemFallbacks();
		overlay.renderer = Renderer.create();
		overlay.context = new UiContext(null, overlay.fonts);
		overlay.binding = UiSurfaceBinding.attach(overlay.context, window, surface, events);
		overlay.resizeSubscription = surface.onResize(overlay.resize);
		overlay.owner = window.registerDependent(overlay.dispose);
		attached = true;
		return overlay;
	}

	function new(surface:Surface, logicalWidth:Float, fonts:FontCollection) {
		this.surface = surface;
		this.logicalWidth = logicalWidth;
		this.fonts = fonts;
		layout = new LayoutFrame(logicalWidth, 1.0);
		frameInfo = new FrameInfo(logicalWidth, 1.0, 1, 1, 1.0);
	}

	function scaleFor(width:Int):Float return width / logicalWidth;

	function resize(width:Int, height:Int, framebufferWidth:Int, framebufferHeight:Int):Void {
		if (width > 0) binding.setCoordinateScale(scaleFor(width));
	}

	public function frameStep(view:View, frame:SurfaceFrame, tick:FrameTick):SurfaceFrameStep {
		if (disposed)
			throw BindingError.disposed("UiOverlay.frameStep", "The UI overlay has been disposed");
		var scale = scaleFor(tick.width);
		var height = tick.height / scale;
		if (dirty || lastView != view || context.isDirty() || context.needsAnimationFrame
			|| tick.width != lastWidth || tick.height != lastHeight) {
			layout.setViewport(logicalWidth, height);
			layout.deltaSeconds = tick.deltaSeconds;
			dirty = false;
			try {
				context.submit(view, layout);
			} catch (error:haxe.Exception) {
				dirty = true;
				throw error;
			}
			lastView = view;
			lastWidth = tick.width;
			lastHeight = tick.height;
		}
		frameInfo.set(logicalWidth, height, tick.width, tick.height, scale);
		return context.frameStep(renderer, frame, frameInfo);
	}

	/** Requests a new build after the application changes state read by the view. */
	public function invalidate():Void {
		if (disposed) return;
		dirty = true;
		surface.requestFrame();
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		defer if (owner != null) owner.detach();
		defer fonts.dispose();
		defer if (renderer != null) renderer.dispose();
		defer if (context != null) context.dispose();
		defer if (binding != null) binding.dispose();
		if (resizeSubscription != null) resizeSubscription.dispose();
	}
}
