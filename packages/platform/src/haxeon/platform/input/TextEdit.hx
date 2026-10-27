package haxeon.platform.input;

import nativekit.ffi.NativeKitTypes.TextEditAction;

class TextEdit {
	public final action:TextEditAction;
	public final text:Null<String>;
	public final replaceStart:Int;
	public final replaceEnd:Int;
	public final selectionStart:Int;
	public final selectionEnd:Int;
	public final compositionStart:Int;
	public final compositionEnd:Int;
	public final selectionAffinity:Int;
	public final historyKind:Int;

	public function new(action:TextEditAction, text:Null<String>, replaceStart:Int, replaceEnd:Int,
		selectionStart:Int, selectionEnd:Int, compositionStart:Int, compositionEnd:Int,
		?selectionAffinity:Int = 0, ?historyKind:Int = 0) {
		this.action = action; this.text = text;
		this.replaceStart = replaceStart; this.replaceEnd = replaceEnd;
		this.selectionStart = selectionStart; this.selectionEnd = selectionEnd;
		this.compositionStart = compositionStart; this.compositionEnd = compositionEnd;
		this.selectionAffinity = selectionAffinity;
		this.historyKind = historyKind;
	}
}
