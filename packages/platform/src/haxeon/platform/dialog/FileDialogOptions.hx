package haxeon.platform.dialog;

import haxeon.platform.dialog.FileDialogFilter;
import nativekit.ffi.NativeKitTypes.DialogFlags;
import nativekit.ffi.NativeKitTypes.FileDialogOptions as NativeFileDialogOptions;

/** Title, initial resource location, suggested name, flags, and chooser filters. */
class FileDialogOptions {
	/** The dialog's title, or null. */
	public var title:Null<String> = null;

	/** Where it opens, or null. */
	public var initialPath:Null<String> = null;

	/** The name a save dialog suggests, or null. */
	public var suggestedName:Null<String> = null;

	/** Its behaviour, such as allowing several files. */
	public var flags:DialogFlags = DialogFlags.empty();

	/** The file types it offers. */
	public var filters:Array<FileDialogFilter> = [];

	/** The default options. */
	public function new() {}

	/** The generated ABI record for these options, for the `Native` interop entry points. */
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
