package haxeon.platform;

import haxeon.platform.DisposalRegistration;
import haxeon.platform.Window;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.OwnedWebViewHandle;
import nativekit.ffi.NativeKitTypes.Result;
import nativekit.ffi.NativeKitTypes.WebViewHandle;
import nativekit.ffi.NativeKitTypes.WebviewOptions as NativeWebViewOptions;

/** Owns one native child WebView. */
class WebView implements Disposable {
	final value:WebViewHandle;
	var disposed:Bool = false;
	var owner:Null<DisposalRegistration>;

	/** Transfers the fresh native handle into this retryable managed owner. */
	@:allow(haxeon.platform.Window)
	private function new(owned:OwnedWebViewHandle) {
		this.value = owned.borrow();
	}

	/** A web view in the native window `parent`, from a generated options record; the caller disposes it. */
	public static function createNative(parent:Handle, options:NativeWebViewOptions):WebView
		return new WebView(NativeKit.nk_webview_create_checked(parent, options));

	/** Shows or hides it. */
	public function show(visible:Bool):Void {
		ensureLive();
		check(NativeKit.nk_webview_show(value, visible), "webview.show");
	}

	/** Moves and resizes it within its window. */
	public function setBounds(x:Int, y:Int, width:Int, height:Int):Void {
		ensureLive();
		check(NativeKit.nk_webview_set_bounds(value, x, y, width, height), "webview.setBounds");
	}

	/** Loads `html`, resolving relative URLs against `baseUrl`. */
	public function setHtml(html:String, ?baseUrl:String):Void {
		ensureLive();
		check(NativeKit.nk_webview_set_html(value, html, baseUrl), "webview.setHtml");
	}

	/** Loads `url`. */
	public function navigate(url:String):Void {
		ensureLive();
		check(NativeKit.nk_webview_navigate(value, url), "webview.navigate");
	}

	/** Reloads the page. */
	public function reload():Void {
		ensureLive();
		check(NativeKit.nk_webview_reload(value), "webview.reload");
	}

	/** The native web view, for interop. */
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

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.platform.Window)
	function attachOwner(registration:DisposalRegistration):Void owner = registration;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("WebView.ensureLive", "NativeKit WebView has been disposed");
	}

	static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw NativeKitStatus.failure(status, operation, NativeKit.nk_last_error());
	}
}
