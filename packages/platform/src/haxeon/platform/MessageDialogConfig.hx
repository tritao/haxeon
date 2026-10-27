package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** Managed options; native ABI storage is created only at the interop boundary. */
class MessageDialogConfig {
	public var message:String;
	public var title:Null<String> = null;
	public var kind:MessageKind = cast 0;
	public var buttons:MessageButtons = cast 0;

	public function new(message:String) {
		this.message = message;
	}

	public function nativeValue():MessageDialogOptions {
		var value = new MessageDialogOptions();
		value.set_struct_size(MessageDialogOptions.size());
		value.set_message(message);
		value.set_title(title);
		value.set_kind(kind);
		value.set_buttons(buttons);
		return value;
	}
}
