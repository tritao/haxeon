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
		value.struct_size = NativeMessageDialogOptions.byteSize();
		value.message = message;
		value.title = title;
		value.kind = kind;
		value.buttons = buttons;
		return value;
	}
}
