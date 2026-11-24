package haxeon.platform;

import nativekit.ffi.NativeKitTypes.WebviewFlags;
import nativekit.ffi.NativeKitTypes.WebviewOptions as NativeWebViewOptions;

/** Logical bounds, flags, and initial URL for an owned child WebView. */
class WebViewOptions {
	public var width:Int;
	public var height:Int;
	public var x:Int = 0;
	public var y:Int = 0;
	public var flags:WebviewFlags = WebviewFlags.empty();
	public var initialUrl:Null<String> = null;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	public function nativeValue():NativeWebViewOptions {
		var value = new NativeWebViewOptions();
		value.struct_size = NativeWebViewOptions.byteSize();
		value.width = width;
		value.height = height;
		value.x = x;
		value.y = y;
		value.flags = flags;
		value.initial_url = initialUrl;
		return value;
	}
}
