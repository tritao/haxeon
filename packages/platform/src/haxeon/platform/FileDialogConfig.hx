package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** Managed options; native ABI storage is created only at the interop boundary. */
class FileDialogConfig {
	public var title:Null<String> = null;
	public var initialPath:Null<String> = null;
	public var suggestedName:Null<String> = null;
	public var flags:DialogFlags = cast 0;
	public var filters:Array<FileDialogFilter> = [];

	public function new() {
	}

	public function nativeValue():FileDialogOptions {
		var value = new FileDialogOptions();
		value.set_struct_size(FileDialogOptions.size());
		value.set_title(title);
		value.set_initial_path(initialPath);
		value.set_suggested_name(suggestedName);
		value.set_flags(flags);
		value.set_filters([for (filter in filters) filter.nativeValue()]);
		return value;
	}
}
