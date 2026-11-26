package haxeon.platform;

import nativekit.ffi.NativeKitTypes.WebviewFlags;
import nativekit.ffi.NativeKitTypes.WebviewOptions as NativeWebViewOptions;

/** Logical bounds, flags, and initial URL for an owned child WebView. */
class WebViewOptions {
	/** Its width. */
	public var width:Int;

	/** Its height. */
	public var height:Int;

	/** Its left edge within the window. */
	public var x:Int = 0;

	/** Its top edge within the window. */
	public var y:Int = 0;

	/** Its behaviour, such as developer tools. */
	public var flags:WebviewFlags = WebviewFlags.empty();

	/** The page it opens, or null. */
	public var initialUrl:Null<String> = null;

	/** Options for a `width` by `height` web view. */
	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	/** The generated ABI record for these options, for the `Native` interop entry points. */
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
