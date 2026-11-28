package haxeon.platform.dialog;

import nativekit.ffi.NativeKitTypes.MessageResult;

/** How the user answered a message dialog: the button, and whether they ticked its checkbox, when it had one. */
class MessageAnswer {
	/** The button chosen. */
	public final button:MessageResult;

	/** Whether the dialog's checkbox (`MessageDialogOptions.checkboxLabel`) was ticked; false when it had none. */
	public final checkboxChecked:Bool;

	/** An answer of `button`, with the checkbox `checkboxChecked`. */
	public function new(button:MessageResult, checkboxChecked:Bool) {
		this.button = button;
		this.checkboxChecked = checkboxChecked;
	}
}
