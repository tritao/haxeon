package haxeon.platform.dialog;

import nativekit.ffi.NativeKitTypes.MessageButtons;
import nativekit.ffi.NativeKitTypes.MessageDialogOptions as NativeMessageDialogOptions;
import nativekit.ffi.NativeKitTypes.MessageKind;

/** Message text, presentation kind, and buttons for a native dialog. */
class MessageDialogOptions {
	/** What the dialog says. */
	public var message:String;

	/** Its title, or null. */
	public var title:Null<String> = null;

	/** Its icon and tone: information, warning or error. */
	public var kind:MessageKind = cast 0;

	/** Which buttons it offers. */
	public var buttons:MessageButtons = cast 0;

	/** The affirmative (Yes) button's label, or null for the platform's. */
	public var yesLabel:Null<String> = null;

	/** A checkbox's label, such as "Don't ask again", or null for none; the answer says whether it was ticked. */
	public var checkboxLabel:Null<String> = null;

	/** A dialog saying `message`. */
	public function new(message:String) {
		this.message = message;
	}

	/** The generated ABI record for these options, for the `Native` interop entry points. */
	public function nativeValue():NativeMessageDialogOptions {
		var value = new NativeMessageDialogOptions();
		value.struct_size = NativeMessageDialogOptions.byteSize();
		value.message = message;
		value.title = title;
		value.kind = kind;
		value.buttons = buttons;
		value.yes_label = yesLabel;
		value.checkbox_label = checkboxLabel;
		return value;
	}
}
