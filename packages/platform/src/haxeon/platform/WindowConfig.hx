package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** Managed options; native ABI storage is created only at the interop boundary. */
class WindowConfig {
	public var width:Int;
	public var height:Int;
	public var title:Null<String> = null;
	public var flags:WindowFlags = cast 0;
	public var kind:WindowKind = cast 0;
	public var owner:Null<NativeKitWindow> = null;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	public function nativeValue():WindowOptions {
		var value = new WindowOptions();
		value.set_struct_size(WindowOptions.size());
		value.set_width(width);
		value.set_height(height);
		value.set_title(title);
		value.set_flags(flags);
		value.set_kind(kind);
		if (owner != null) value.set_owner(owner.nativeHandle());
		return value;
	}
}
