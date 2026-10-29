package haxeon.ui.widgets.text;

/**
	A bounded UTF-8 window with absolute document code-point offsets, and the selection as reported with it: clamped
	into the window, since platform text input requires it there, when a selection reaches past it.
**/
class TextInputWindow {
	public final text:String;
	public final start:CodepointOffset;
	public final end:CodepointOffset;
	public final selectionStart:CodepointOffset;
	public final selectionEnd:CodepointOffset;

	public function new(text:String, start:CodepointOffset, end:CodepointOffset, ?selectionStart:CodepointOffset,
			?selectionEnd:CodepointOffset) {
		this.text = text == null ? "" : text;
		this.start = start;
		this.end = end;
		this.selectionStart = selectionStart == null ? start : selectionStart;
		this.selectionEnd = selectionEnd == null ? this.selectionStart : selectionEnd;
	}
}
