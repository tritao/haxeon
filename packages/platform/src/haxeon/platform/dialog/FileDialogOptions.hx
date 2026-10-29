package haxeon.platform.dialog;

import haxeon.platform.dialog.FileDialogFilter;
import nativekit.ffi.NativeKitTypes.DialogFlags;
import nativekit.ffi.NativeKitTypes.FileDialogOptions as NativeFileDialogOptions;

/** Title, initial resource location, suggested name, flags, and chooser filters. */
class FileDialogOptions {
	public var title:Null<String> = null;
	public var initialPath:Null<String> = null;
	public var suggestedName:Null<String> = null;
	public var flags:DialogFlags = cast 0;
	public var filters:Array<FileDialogFilter> = [];

	public function new() {
	}

	public function nativeValue():NativeFileDialogOptions {
		var value = new NativeFileDialogOptions();
		value.set_struct_size(NativeFileDialogOptions.size());
		value.set_title(title);
		value.set_initial_path(initialPath);
		value.set_suggested_name(suggestedName);
		value.set_flags(flags);
		value.set_filters([for (filter in filters) filter.nativeValue()]);
		return value;
	}
}
