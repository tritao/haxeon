package haxeon.platform;

import haxeon.platform.Window;
import nativekit.ffi.NativeKitTypes.WindowFlags;
import nativekit.ffi.NativeKitTypes.WindowKind;
import nativekit.ffi.NativeKitTypes.WindowOptions as NativeWindowOptions;

/** Initial logical size, title, ownership, and flags for a window. */
class WindowOptions {
	public var width:Int;
	public var height:Int;
	public var title:Null<String> = null;
	public var flags:WindowFlags = cast 0;
	public var kind:WindowKind = cast 0;
	public var owner:Null<Window> = null;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	public function nativeValue():NativeWindowOptions {
		var value = new NativeWindowOptions();
		value.set_struct_size(NativeWindowOptions.size());
		value.set_width(width);
		value.set_height(height);
		value.set_title(title);
		value.set_flags(flags);
		value.set_kind(kind);
		if (owner != null) value.set_owner(owner.nativeHandle());
		return value;
	}
}
