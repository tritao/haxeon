package haxeon.platform.input;

import nativekit.ffi.NativeKitConstants;
import nativekit.ffi.NativeKitTypes.TextInputAction;
import nativekit.ffi.NativeKitTypes.TextInputFlags;
import nativekit.ffi.NativeKitTypes.TextInputState as NativeTextInputState;
import nativekit.ffi.NativeKitTypes.TextInputType;

/** Managed IME state. Text positions use NativeKit's document coordinate convention. */
class TextInputState {
	/** The text around the selection the input method may read. */
	public var text:String;

	/** Where `text` starts in the document, in code points. */
	public var textStart:Int = 0;

	/** The whole document's length, in code points. */
	public var documentLength:Int;

	/** Where the selection starts, in document code points. */
	public var selectionStart:Int;

	/** Where it ends. */
	public var selectionEnd:Int;

	/** Where the composition starts, or null for none. */
	public var compositionStart:Null<Int> = null;

	/** Where it ends, or null for none. */
	public var compositionEnd:Null<Int> = null;

	/** What kind of text it is, such as email or a number. */
	public var inputType:TextInputType = TextInputType.Text;

	/** Input hints, such as no autocorrection. */
	public var flags:TextInputFlags = TextInputFlags.empty();

	/** What the return key does. */
	public var action:TextInputAction = TextInputAction.Default;

	/** The caret's x, in surface-local logical pixels. */
	public var cursorX:Float = 0;

	/** The caret's y. */
	public var cursorY:Float = 0;

	/** The caret's width. */
	public var cursorWidth:Float = 0;

	/** The caret's height. */
	public var cursorHeight:Float = 0;

	/** The state of `text` with the given selection. */
	public function new(text:String, documentLength:Int, selectionStart:Int, selectionEnd:Int) {
		this.text = text;
		this.documentLength = documentLength;
		this.selectionStart = selectionStart;
		this.selectionEnd = selectionEnd;
	}

	/** Creates ABI storage for the duration of a platform call. */
	public function nativeValue():NativeTextInputState {
		var value = new NativeTextInputState();
		value.struct_size = NativeTextInputState.byteSize();
		value.text = text;
		value.text_start = textStart;
		value.document_length = documentLength;
		value.selection_start = selectionStart;
		value.selection_end = selectionEnd;
		value.composition_start = compositionStart == null
			? NativeKitConstants.NK_TEXT_POSITION_NONE : compositionStart;
		value.composition_end = compositionEnd == null ? NativeKitConstants.NK_TEXT_POSITION_NONE : compositionEnd;
		value.input_type = inputType;
		value.flags = flags;
		value.action = action;
		value.cursor_x = cursorX;
		value.cursor_y = cursorY;
		value.cursor_width = cursorWidth;
		value.cursor_height = cursorHeight;
		return value;
	}
}
