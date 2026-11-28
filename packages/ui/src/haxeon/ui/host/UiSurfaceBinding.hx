package haxeon.ui.host;

import haxeon.platform.DisposalRegistration;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.Window;
import haxeon.platform.event.EventPump;
import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.Renderer;
import haxeon.ui.core.NativeInputAdapter;
import haxeon.ui.core.UiContext;
import nativekit.ffi.NativeKitTypes;

/** Connects a borrowed UI context and surface to the platform input pump. */
internal class UiSurfaceBinding implements Disposable {
	final context:UiContext;
	final input:NativeInputAdapter;
	final surface:Surface;
	var windowAttached = false;
	var owner:Null<DisposalRegistration>;
	var disposed = false;

	public static function attach(context:UiContext, window:Window, surface:Surface,
			events:EventPump, redrawOnInput:Bool = false):UiSurfaceBinding {
		return connect(context, window.nativeHandle(), surface, events, redrawOnInput, window);
	}

	/** Also supports hosts whose window and surface are managed by native code. */
	public static function attachNative(context:UiContext, window:WindowHandle, surface:Surface,
			events:EventPump, ?requestFrame:Void->Void, redrawOnInput:Bool = false):UiSurfaceBinding {
		return connect(context, window, surface, events, redrawOnInput, null, requestFrame);
	}

	static function connect(context:UiContext, window:WindowHandle, surface:Surface, events:EventPump,
			redrawOnInput:Bool, managedWindow:Null<Window>, ?requestFrame:Void->Void):UiSurfaceBinding {
		var binding = new UiSurfaceBinding(context, window, surface);
		var ready = false;
		defer if (!ready) binding.dispose();
		context.attachPlatformSurface(surface);
		if (window.isValid()) {
			context.attachPlatformWindow(window);
			binding.windowAttached = true;
		}
		binding.input.attach(events, redrawOnInput);
		context.clipboard.attach(events.requests);
		context.onAnimationFrameRequested = requestFrame == null ? surface.requestFrame : requestFrame;
		if (managedWindow != null)
			binding.owner = managedWindow.registerDependent(binding.dispose);
		ready = true;
		return binding;
	}

	function new(context:UiContext, window:WindowHandle, surface:Surface) {
		this.context = context;
		this.surface = surface;
		var surfaceSource = new Handle(surface.nativeHandle().rawValue);
		var source = window.isValid() ? new Handle(window.rawValue) : surfaceSource;
		input = new NativeInputAdapter(context, source, surfaceSource);
	}

	public function setCoordinateScale(value:Float):Void {
		input.coordinateScale = value;
		context.textInput.coordinateScale = value;
		context.platformCoordinateScale = value;
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		context.onAnimationFrameRequested = null;
		defer if (owner != null) owner.detach();
		defer context.detachPlatformSurface(surface);
		defer if (windowAttached) context.detachPlatformWindow();
		input.detach();
		context.clipboard.detach();
	}
}

/** Reuses the layout frame and render target for every callback on one surface. */
internal class UiSurfaceFrame {
	public final layout:LayoutFrame;
	public final dimensions:FrameInfo;
	final target:Surface;

	public function new(surface:Surface, width:Int, height:Int) {
		layout = new LayoutFrame(width, height);
		dimensions = new FrameInfo(width, height, width, height, 1.0);
		target = surface;
	}

	public function configure(width:Float, height:Float, framebufferWidth:Int, framebufferHeight:Int,
			scale:Float, deltaSeconds:Float):Void {
		layout.setViewport(width, height);
		layout.deltaSeconds = deltaSeconds;
		dimensions.set(width, height, framebufferWidth, framebufferHeight, scale);
	}

	public function prepare(renderer:Renderer):Int
		return renderer.prepare(target);

	public function render(context:UiContext, renderer:Renderer, ?acquired:SurfaceFrame):Void {
		if (acquired == null) {
			context.render(renderer, target, dimensions);
		} else {
			var step = context.frameStep(renderer, acquired, dimensions);
			defer step.dispose();
			acquired.submit([step]);
		}
	}
}
