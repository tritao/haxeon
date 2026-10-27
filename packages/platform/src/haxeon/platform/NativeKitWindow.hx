package haxeon.platform;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitSurface;
import haxeon.platform.NativeKitWebView;

/** Owns one NativeKit top-level window and resources created inside it. */
class NativeKitWindow {
	final value:WindowHandle;
	final children = new NativeResourceRegistry();
	var owner:Null<NativeResourceRegistry.NativeResourceRegistration>;
	var disposed:Bool = false;
	var disposing:Bool = false;

	/** Transfers the fresh native handle into this retryable managed owner. */
	@:allow(NativeKitRuntime)
	private function new(owned:OwnedWindowHandle) {
		this.value = owned.borrow();
	}

	public function nativeHandle():WindowHandle {
		ensureLive();
		return value;
	}

	/** Replaces the logical hit-test regions used by custom native window chrome. */
	public function setDecorationRegions(regions:Array<DecorationRegion>):Void
		setDecorationRegionsNative([for (region in regions) region.nativeValue()]);

	/** Raw ABI entrypoint for native window chrome integrations. */
	public function setDecorationRegionsNative(regions:Array<WindowDecorationRegion>):Void {
		ensureLive();
		NativeKit.nk_window_set_decoration_regions_checked(value, regions);
	}

	public function createSurface(options:SurfaceConfig):NativeKitSurface
		return createSurfaceNative(options.nativeValue());

	public function createSurfaceNative(options:SurfaceOptions):NativeKitSurface {
		ensureCanCreate();
		var surface = NativeKitSurface.adopt(NativeKit.nk_surface_create_checked(new Handle(value.rawValue()), options));
		surface.attachOwner(children.register(surface.dispose));
		return surface;
	}

	public function createWebView(options:WebViewConfig):NativeKitWebView
		return createWebViewNative(options.nativeValue());

	public function createWebViewNative(options:WebviewOptions):NativeKitWebView {
		ensureCanCreate();
		var webview = new NativeKitWebView(NativeKit.nk_webview_create_checked(new Handle(value.rawValue()), options));
		webview.attachOwner(children.register(webview.dispose));
		return webview;
	}

	/** Registers an adapter-owned child that must be released before this window. */
	public function registerDependent(dispose:Void->Void):NativeResourceRegistry.NativeResourceRegistration {
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

	@:allow(NativeKitRuntime)
	function attachOwner(registration:NativeResourceRegistry.NativeResourceRegistration):Void owner = registration;

	function ensureCanCreate():Void {
		ensureLive();
		if (disposing) throw "Cannot create children while a NativeKit window is being disposed";
	}

	function ensureLive():Void {
		if (disposed)
			throw "NativeKit window has been disposed";
	}
}
