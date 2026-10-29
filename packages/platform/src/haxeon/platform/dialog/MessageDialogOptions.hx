package haxeon.platform.dialog;

import nativekit.ffi.NativeKitTypes.MessageButtons;
import nativekit.ffi.NativeKitTypes.MessageDialogOptions as NativeMessageDialogOptions;
import nativekit.ffi.NativeKitTypes.MessageKind;

/** Message text, presentation kind, and buttons for a native dialog. */
class MessageDialogOptions {
	public var message:String;
	public var title:Null<String> = null;
	public var kind:MessageKind = cast 0;
	public var buttons:MessageButtons = cast 0;

	public function new(message:String) {
		this.message = message;
	}

	public function nativeValue():NativeMessageDialogOptions {
		var value = new NativeMessageDialogOptions();
		value.set_struct_size(NativeMessageDialogOptions.size());
		value.set_message(message);
		value.set_title(title);
		value.set_kind(kind);
		value.set_buttons(buttons);
		return value;
	}
}
