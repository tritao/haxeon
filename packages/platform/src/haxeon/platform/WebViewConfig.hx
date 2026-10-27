package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** Managed options; native ABI storage is created only at the interop boundary. */
class WebViewConfig {
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

	public function nativeValue():WebviewOptions {
		var value = new WebviewOptions();
		value.set_struct_size(WebviewOptions.size());
		value.set_width(width);
		value.set_height(height);
		value.set_x(x);
		value.set_y(y);
		value.set_flags(flags);
		value.set_initial_url(initialUrl);
		return value;
	}
}
