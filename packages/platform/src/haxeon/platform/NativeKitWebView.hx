package haxeon.platform;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitError;

/** Owns one native child WebView. */
class NativeKitWebView {
	final value:WebViewHandle;
	var disposed:Bool = false;
	var owner:Null<NativeResourceRegistry.NativeResourceRegistration>;

	/** Transfers the fresh native handle into this retryable managed owner. */
	@:allow(NativeKitWindow)
	private function new(owned:OwnedWebViewHandle) {
		this.value = owned.borrow();
	}

	public static function create(parent:NativeKitWindow, options:WebViewConfig):NativeKitWebView
		return parent.createWebView(options);

	public static function createNative(parent:Handle, options:WebviewOptions):NativeKitWebView
		return new NativeKitWebView(NativeKit.nk_webview_create_checked(parent, options));

	public function show(visible:Bool):Void {
		ensureLive();
		check(NativeKit.nk_webview_show(value, visible), "webview.show");
	}

	public function setBounds(x:Int, y:Int, width:Int, height:Int):Void {
		ensureLive();
		check(NativeKit.nk_webview_set_bounds(value, x, y, width, height), "webview.setBounds");
	}

	public function setHtml(html:String, ?baseUrl:String):Void {
		ensureLive();
		check(NativeKit.nk_webview_set_html(value, html, baseUrl), "webview.setHtml");
	}

	public function navigate(url:String):Void {
		ensureLive();
		check(NativeKit.nk_webview_navigate(value, url), "webview.navigate");
	}

	public function reload():Void {
		ensureLive();
		check(NativeKit.nk_webview_reload(value), "webview.reload");
	}

	public function nativeHandle():WebViewHandle {
		ensureLive();
		return value;
	}

	public function dispose():Void {
		if (disposed)
			return;
		NativeKit.nk_webview_destroy_checked(value);
		disposed = true;
		if (owner != null) owner.detach();
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(NativeKitWindow)
	function attachOwner(registration:NativeResourceRegistry.NativeResourceRegistration):Void owner = registration;

	function ensureLive():Void {
		if (disposed)
			throw "NativeKit WebView has been disposed";
	}

	static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw new NativeKitError(status, operation, NativeKit.nk_last_error());
	}
}
