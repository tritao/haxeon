package haxeon.platform.dialog;

import nativekit.ffi.NativeKitTypes.DialogFilter;

/** One named group of file patterns accepted by a resource dialog. */
class FileDialogFilter {
	/** What the filter shows, such as "Images". */
	public var name:String;

	/** Its patterns, such as `*.png;*.jpg`. */
	public var patterns:String;

	/** A filter `name` of `patterns`. */
	public function new(name:String, patterns:String) {
		this.name = name;
		this.patterns = patterns;
	}

	/** The generated ABI record for it. */
	public function nativeValue():DialogFilter {
		var value = new DialogFilter();
		value.set_name(name);
		value.set_patterns(patterns);
		return value;
	}
}
