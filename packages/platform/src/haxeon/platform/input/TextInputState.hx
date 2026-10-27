package haxeon.platform.input;

import nativekit.ffi.NativeKitConstants;
import nativekit.ffi.NativeKitTypes.TextInputAction;
import nativekit.ffi.NativeKitTypes.TextInputFlags;
import nativekit.ffi.NativeKitTypes.TextInputState as NativeTextInputState;
import nativekit.ffi.NativeKitTypes.TextInputType;

/** Managed IME state. Text positions use NativeKit's document coordinate convention. */
class TextInputState {
	public var text:String;
	public var textStart:Int = 0;
	public var documentLength:Int;
	public var selectionStart:Int;
	public var selectionEnd:Int;
	public var compositionStart:Null<Int> = null;
	public var compositionEnd:Null<Int> = null;
	public var inputType:TextInputType = TextInputType.Text;
	public var flags:TextInputFlags = cast 0;
	public var action:TextInputAction = TextInputAction.Default;
	public var cursorX:Float = 0;
	public var cursorY:Float = 0;
	public var cursorWidth:Float = 0;
	public var cursorHeight:Float = 0;

	public function new(text:String, documentLength:Int, selectionStart:Int, selectionEnd:Int) {
		this.text = text;
		this.documentLength = documentLength;
		this.selectionStart = selectionStart;
		this.selectionEnd = selectionEnd;
	}

	/** Creates ABI storage for the duration of a platform call. */
	public function nativeValue():NativeTextInputState {
		var value = new NativeTextInputState();
		value.set_struct_size(NativeTextInputState.size());
		value.set_text(text);
		value.set_text_start(textStart);
		value.set_document_length(documentLength);
		value.set_selection_start(selectionStart);
		value.set_selection_end(selectionEnd);
		value.set_composition_start(compositionStart == null ? NativeKitConstants.NK_TEXT_POSITION_NONE : compositionStart);
		value.set_composition_end(compositionEnd == null ? NativeKitConstants.NK_TEXT_POSITION_NONE : compositionEnd);
		value.set_input_type(inputType);
		value.set_flags(flags);
		value.set_action(action);
		value.set_cursor_x(cursorX);
		value.set_cursor_y(cursorY);
		value.set_cursor_width(cursorWidth);
		value.set_cursor_height(cursorHeight);
		return value;
	}
}
