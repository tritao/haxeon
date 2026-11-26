package haxeon.platform.input;

import nativekit.ffi.NativeKitTypes.TextEditAction;
import nativekit.ffi.NativeKitTypes.TextEditHistoryKind;

/** An edit the input method made: what to replace and where the selection and composition end up. */
class TextEdit {
	/** Whether it composes, commits, deletes or moves the selection. */
	public final action:TextEditAction;

	/** The inserted text, or null. */
	public final text:Null<String>;

	/** Where the replaced range starts, in document code points. */
	public final replaceStart:Int;

	/** Where it ends. */
	public final replaceEnd:Int;

	/** Where the selection starts afterwards. */
	public final selectionStart:Int;

	/** Where it ends afterwards. */
	public final selectionEnd:Int;

	/** Where the composition starts afterwards, or -1 for none. */
	public final compositionStart:Int;

	/** Where it ends afterwards, or -1 for none. */
	public final compositionEnd:Int;

	/** Which side of a line break the caret sits on; zero is the default. */
	public final selectionAffinity:Int;

	/** How the edit groups for undo. */
	public final historyKind:TextEditHistoryKind;

	/** An edit of `action`. */
	public function new(action:TextEditAction, text:Null<String>, replaceStart:Int, replaceEnd:Int,
			selectionStart:Int, selectionEnd:Int, compositionStart:Int, compositionEnd:Int,
			?selectionAffinity:Int = 0, ?historyKind:TextEditHistoryKind = TextEditHistoryKind.Generic) {
		this.action = action;
		this.text = text;
		this.replaceStart = replaceStart;
		this.replaceEnd = replaceEnd;
		this.selectionStart = selectionStart;
		this.selectionEnd = selectionEnd;
		this.compositionStart = compositionStart;
		this.compositionEnd = compositionEnd;
		this.selectionAffinity = selectionAffinity;
		this.historyKind = historyKind;
	}
}
