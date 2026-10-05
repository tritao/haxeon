package nativekit.ui.widgets.text;

import Color;
import LayoutStyle;
import TextStyle;
import nativekit.ui.core.View;
import nativekit.editorkit.TextDocument;

/** Multiline text editor sharing the TextField IME and selection model. */
class TextArea extends TextField implements View {
	public function new(key:String, value:String = "", ?onChange:String->Void,
			?style:LayoutStyle, ?label:String, ?textStyle:TextStyle, ?textColor:Color,
			?document:TextDocument, ?onEdit:EditTransaction->Void) {
		super(key, value, onChange, style, label, textStyle, textColor, true,
			document, onEdit);
	}

	/** Creates a multiline editor backed by a shared EditorKit document. */
	public static function withDocument(key:String, document:TextDocument,
			?onEdit:EditTransaction->Void, ?style:LayoutStyle, ?label:String,
			?textStyle:TextStyle, ?textColor:Color):TextArea
		return new TextArea(key, "", null, style, label, textStyle, textColor,
			document, onEdit);
}
