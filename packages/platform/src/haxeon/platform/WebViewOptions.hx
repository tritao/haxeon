package haxeon.platform;

import nativekit.ffi.NativeKitTypes.WebviewFlags;
import nativekit.ffi.NativeKitTypes.WebviewOptions as NativeWebViewOptions;

/** Logical bounds, flags, and initial URL for an owned child WebView. */
class WebViewOptions {
	public var width:Int;
	public var height:Int;
	public var x:Int = 0;
	public var y:Int = 0;
	public var flags:WebviewFlags = cast 0;
	public var initialUrl:Null<String> = null;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	public function nativeValue():NativeWebViewOptions {
		var value = new NativeWebViewOptions();
		value.set_struct_size(NativeWebViewOptions.size());
		value.set_width(width);
		value.set_height(height);
		value.set_x(x);
		value.set_y(y);
		value.set_flags(flags);
		value.set_initial_url(initialUrl);
		return value;
	}
}
