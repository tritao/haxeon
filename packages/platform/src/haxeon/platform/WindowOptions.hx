package haxeon.platform;

import haxeon.platform.Window;
import nativekit.ffi.NativeKitTypes.WindowFlags;
import nativekit.ffi.NativeKitTypes.WindowKind;
import nativekit.ffi.NativeKitTypes.WindowOptions as NativeWindowOptions;

/** Initial logical size, title, ownership, and flags for a window. */
class WindowOptions {
	/** Its width, in logical pixels. */
	public var width:Int;

	/** Its height, in logical pixels. */
	public var height:Int;

	/** Its title, or null. */
	public var title:Null<String> = null;

	/** Its behaviour, such as resizable or borderless. */
	public var flags:WindowFlags = WindowFlags.empty();

	/** What kind of window it is. */
	public var kind:WindowKind = cast 0;

	/** The window it belongs to, for dialogs and tool windows. */
	public var owner:Null<Window> = null;

	/** Options for a `width` by `height` window. */
	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	/** The generated ABI record for these options, for the `Native` interop entry points. */
	public function nativeValue():NativeWindowOptions {
		var value = new NativeWindowOptions();
		value.struct_size = NativeWindowOptions.byteSize();
		value.width = width;
		value.height = height;
		value.title = title;
		value.flags = flags;
		value.kind = kind;
		if (owner != null) value.owner = owner.nativeHandle();
		return value;
	}
}
