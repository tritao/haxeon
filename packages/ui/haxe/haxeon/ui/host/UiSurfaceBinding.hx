package haxeon.ui.host;

import haxeon.platform.DisposalRegistration;
import haxeon.platform.Surface;
import haxeon.platform.FrameTick;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.SurfaceFrameStep;
import haxeon.platform.event.EventSubscription;
import haxeon.ui.LayoutFrame;
import haxeon.ui.FrameInfo;
import haxeon.ui.Renderer;
import haxeon.ui.core.View;
import haxeon.platform.Window;
import haxeon.platform.event.EventPump;
import haxeon.ui.core.NativeInputAdapter;
import haxeon.ui.core.UiContext;
import nativekit.ffi.NativeKitTypes;

/** Connects a borrowed UI context and surface to the platform input pump. */
class UiSurfaceBinding implements Disposable {
	final context:UiContext;
	final input:NativeInputAdapter;
	final surface:Surface;
	var windowAttached = false;
	var owner:Null<DisposalRegistration>;
	var disposed = false;
	var fixedWidth = 0.0;
	var layout:LayoutFrame;
	var info:FrameInfo;
	var resizeSubscription:Null<EventSubscription>;
	var lastView:View;
	var lastWidth = 0;
	var lastHeight = 0;
	var frameDirty = true;

	public static function attach(context:UiContext, window:Window, surface:Surface,
			events:EventPump, redrawOnInput:Bool = false):UiSurfaceBinding {
		return connect(context, window.nativeHandle(), surface, events, redrawOnInput, window);
	}

	/** Also supports hosts whose window and surface are managed by native code. */
	public static function attachNative(context:UiContext, window:WindowHandle, surface:Surface,
			events:EventPump, ?requestFrame:Void->Void):UiSurfaceBinding {
		return connect(context, window, surface, events, false, null, requestFrame);
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
		context.onAnimationFrameRequested = requestFrame == null ? surface.requestFrame : requestFrame;
		if (managedWindow != null)
			binding.owner = managedWindow.registerDependent(binding.dispose);
		ready = true;
		return binding;
	}

	function new(context:UiContext, window:WindowHandle, surface:Surface) {
		this.context = context;
		this.surface = surface;
		var surfaceSource = new Handle(surface.nativeHandle().rawValue());
		var source = window.isValid() ? new Handle(window.rawValue()) : surfaceSource;
		input = new NativeInputAdapter(context, source, surfaceSource);
	}

	public function setCoordinateScale(value:Float):Void {
		input.coordinateScale = value;
		context.textInput.coordinateScale = value;
		context.platformCoordinateScale = value;
	}

	/** Configures the logical width of UI drawn into frames owned by the application. */
	public function setFrameWidth(width:Float):Void {
		if (!Math.isFinite(width) || width <= 0)
			throw "UI frame width must be positive";
		if (resizeSubscription == null) {
			resizeSubscription = surface.onResize(function(width, _, _, _) {
				if (width > 0) setCoordinateScale(width / fixedWidth);
			});
		}
		fixedWidth = width;
		layout = new LayoutFrame(width, 1.0);
		info = new FrameInfo(width, 1.0, 1, 1, 1.0);
		frameDirty = true;
	}

	/** Marks application state read during the next view build as changed. */
	public function invalidateFrame():Void {
		frameDirty = true;
		surface.requestFrame();
	}

	/** Builds the view on demand and records its overlay into the acquired frame. */
	public function frameStep(view:View, renderer:Renderer, frame:SurfaceFrame, tick:FrameTick):SurfaceFrameStep {
		if (layout == null)
			throw "Set the UI frame width before recording an overlay";
		var scale = tick.width / fixedWidth;
		var height = tick.height / scale;
		if (frameDirty || lastView != view || context.isDirty() || context.needsAnimationFrame
			|| tick.width != lastWidth || tick.height != lastHeight) {
			layout.setViewport(fixedWidth, height);
			layout.deltaSeconds = tick.deltaSeconds;
			frameDirty = false;
			context.submit(view, layout);
			lastView = view;
			lastWidth = tick.width;
			lastHeight = tick.height;
		}
		info.set(fixedWidth, height, tick.width, tick.height, scale);
		return context.frameStep(renderer, frame, info);
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		context.onAnimationFrameRequested = null;
		defer if (resizeSubscription != null) resizeSubscription.dispose();
		defer if (owner != null) owner.detach();
		defer context.detachPlatformSurface(surface);
		defer if (windowAttached) context.detachPlatformWindow();
		input.detach();
	}
}
