package haxeon.platform.dialog;

import haxeon.platform.dialog.FileDialogFilter;
import nativekit.ffi.NativeKitTypes.DialogFlags;
import nativekit.ffi.NativeKitTypes.FileDialogOptions as NativeFileDialogOptions;

/** Title, initial resource location, suggested name, flags, and chooser filters. */
class FileDialogOptions {
	public var title:Null<String> = null;
	public var initialPath:Null<String> = null;
	public var suggestedName:Null<String> = null;
	public var flags:DialogFlags = DialogFlags.empty();
	public var filters:Array<FileDialogFilter> = [];

	public function new() {}

	public function nativeValue():NativeFileDialogOptions {
		var value = new NativeFileDialogOptions();
		value.struct_size = NativeFileDialogOptions.byteSize();
		value.title = title;
		value.initial_path = initialPath;
		value.suggested_name = suggestedName;
		value.flags = flags;
		value.set_filters([for (filter in filters) filter.nativeValue()]);
		return value;
	}
}
