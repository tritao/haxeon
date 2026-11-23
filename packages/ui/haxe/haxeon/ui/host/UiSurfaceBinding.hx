package haxeon.ui.host;

import haxeon.platform.DisposalRegistration;
import haxeon.platform.Surface;
import haxeon.platform.Window;
import haxeon.platform.event.EventPump;
import haxeon.ui.core.NativeInputAdapter;
import haxeon.ui.core.UiContext;
import nativekit.ffi.NativeKitTypes;

/** Connects a borrowed UI context and surface to the platform input pump. */
class UiSurfaceBinding {
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
			events:EventPump):UiSurfaceBinding {
		return connect(context, window, surface, events, false, null);
	}

	static function connect(context:UiContext, window:WindowHandle, surface:Surface, events:EventPump,
			redrawOnInput:Bool, managedWindow:Null<Window>):UiSurfaceBinding {
		var binding = new UiSurfaceBinding(context, window, surface);
		var ready = false;
		defer if (!ready) binding.dispose();
		context.attachPlatformSurface(surface);
		if (window.isValid()) {
			context.attachPlatformWindow(window);
			binding.windowAttached = true;
		}
		binding.input.attach(events, redrawOnInput);
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

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		defer if (owner != null) owner.detach();
		defer context.detachPlatformSurface(surface);
		defer if (windowAttached) context.detachPlatformWindow();
		input.detach();
	}
}
