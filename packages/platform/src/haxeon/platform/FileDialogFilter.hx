package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** One named group of file patterns accepted by a resource dialog. */
class FileDialogFilter {
	public var name:String;
	public var patterns:String;

	public function new(name:String, patterns:String) {
		this.name = name;
		this.patterns = patterns;
	}

	public function nativeValue():DialogFilter {
		var value = new DialogFilter();
		value.set_name(name);
		value.set_patterns(patterns);
		return value;
	}
}
