package haxeon.platform;

import haxeon.platform.DisposalRegistration;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceOptions;
import haxeon.platform.WebView;
import haxeon.platform.WebViewOptions;
import haxeon.platform.WindowDecorationRegion;
import haxeon.platform.internal.DisposalRegistry;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import nativekit.ffi.NativeKitTypes.InputAction;
import nativekit.ffi.NativeKitTypes.Key;
import nativekit.ffi.NativeKitTypes.Modifiers;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.OwnedWindowHandle;
import nativekit.ffi.NativeKitTypes.SurfaceOptions as NativeSurfaceOptions;
import nativekit.ffi.NativeKitTypes.WebviewOptions as NativeWebViewOptions;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegion as NativeWindowDecorationRegion;
import nativekit.ffi.NativeKitTypes.WindowHandle;

/** Owns one NativeKit top-level window and resources created inside it. */
class Window implements Disposable {
	final value:WindowHandle;
	final events:EventPump;
	final children = new DisposalRegistry();
	var owner:Null<DisposalRegistration>;
	var disposed:Bool = false;
	var disposing:Bool = false;

	/** Transfers the fresh native handle into this retryable managed owner. */
	@:allow(haxeon.platform.Runtime)
	private function new(owned:OwnedWindowHandle, events:EventPump) {
		this.value = owned.borrow();
		this.events = events;
	}

	public function nativeHandle():WindowHandle {
		ensureLive();
		return value;
	}

	/** Receives keys for this window in registration order. Return true to handle a key. */
	public function onKey(handler:Key->Int->InputAction->Modifiers->Bool):EventSubscription {
		ensureCanCreate();
		if (handler == null)
			throw BindingError.invalidArgument("Window.onKey", "Key handler is required");
		return events.listenSource(new Handle(value.rawValue()), function(event) return switch event {
			case Key(_, key, scancode, action, modifiers): handler(key, scancode, action, modifiers);
			case _: false;
		}).ownedBy(children);
	}

	/** Observes a close request from this window. */
	public function onClose(handler:Void->Void):EventSubscription {
		ensureCanCreate();
		if (handler == null)
			throw BindingError.invalidArgument("Window.onClose", "Close handler is required");
		return events.listenSource(new Handle(value.rawValue()), function(event) {
			switch event {
				case WindowClose(_): handler();
				case _:
			}
			return false;
		}).ownedBy(children);
	}

	/** Observes changes to the window's logical client size. */
	public function onResize(handler:Int->Int->Void):EventSubscription {
		ensureCanCreate();
		if (handler == null)
			throw BindingError.invalidArgument("Window.onResize", "Resize handler is required");
		return events.listenSource(new Handle(value.rawValue()), function(event) {
			switch event {
				case WindowResize(_, width, height): handler(width, height);
				case _:
			}
			return false;
		}).ownedBy(children);
	}

	/** Replaces the logical hit-test regions used by custom native window chrome. */
	public function setDecorationRegions(regions:Array<WindowDecorationRegion>):Void
		setDecorationRegionsNative([for (region in regions) region.nativeValue()]);

	/** Raw ABI entrypoint for native window chrome integrations. */
	public function setDecorationRegionsNative(regions:Array<NativeWindowDecorationRegion>):Void {
		ensureLive();
		NativeKit.nk_window_set_decoration_regions_checked(value, regions);
	}

	public function createSurface(options:SurfaceOptions):Surface
		return createSurfaceNative(options.nativeValue());

	public function createSurfaceNative(options:NativeSurfaceOptions):Surface {
		ensureCanCreate();
		var surface = Surface.adopt(NativeKit.nk_surface_create_checked(new Handle(value.rawValue()), options), events);
		surface.attachOwner(children.register(surface.dispose));
		return surface;
	}

	public function createWebView(options:WebViewOptions):WebView
		return createWebViewNative(options.nativeValue());

	public function createWebViewNative(options:NativeWebViewOptions):WebView {
		ensureCanCreate();
		var webview = new WebView(NativeKit.nk_webview_create_checked(new Handle(value.rawValue()), options));
		webview.attachOwner(children.register(webview.dispose));
		return webview;
	}

	/** Registers an adapter-owned child that must be released before this window. */
	public function registerDependent(dispose:Void->Void):DisposalRegistration {
		ensureCanCreate();
		return children.register(dispose);
	}

	/** Destroys children before the window; safe to call more than once. */
	public function dispose():Void {
		if (disposed || disposing)
			return;
		disposing = true;
		try {
			children.releaseAll();
			NativeKit.nk_window_destroy_checked(value);
		} catch (error:Dynamic) {
			disposing = false;
			throw error;
		}
		disposing = false;
		disposed = true;
		if (owner != null) owner.detach();
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.platform.Runtime)
	function attachOwner(registration:DisposalRegistration):Void owner = registration;

	function ensureCanCreate():Void {
		ensureLive();
		if (disposing) throw BindingError.invalidState("Window.ensureCanCreate",
			"Cannot create children while a NativeKit window is being disposed");
	}

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Window.ensureLive", "NativeKit window has been disposed");
	}
}
