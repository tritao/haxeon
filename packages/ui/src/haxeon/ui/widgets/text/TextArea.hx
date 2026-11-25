package haxeon.ui.widgets.text;

import haxeon.editor.TextDocument;
import haxeon.ui.Color;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.core.View;

import haxeon.ui.widgets.text.TextEditorState;
/** Multiline text editor sharing the TextField IME and selection model. */
class TextArea extends TextField implements View {
	/** A multiline editor of `value`; `onChange` receives the text after each edit. Throws when `key` is empty. */
	public function new(key:String, value:String = "", ?onChange:String->Void,
			?style:LayoutStyle, ?label:String, ?textStyle:TextStyle, ?textColor:Color,
			?document:TextDocument, ?onEdit:TextEditTransaction->Void) {
		super(key, value, onChange, style, label, textStyle, textColor, true,
			document, onEdit);
	}

	/** Creates a multiline editor backed by a shared EditorKit document. */
	public static function withDocument(key:String, document:TextDocument,
			?onEdit:TextEditTransaction->Void, ?style:LayoutStyle, ?label:String,
			?textStyle:TextStyle, ?textColor:Color):TextArea
		return new TextArea(key, "", null, style, label, textStyle, textColor,
			document, onEdit);
}
