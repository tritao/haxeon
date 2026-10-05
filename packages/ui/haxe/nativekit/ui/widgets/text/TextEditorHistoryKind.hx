package nativekit.ui.widgets.text;

/** Source/coalescing policy attached to one edit transaction. */
enum TextEditorHistoryKind {
	Generic;
	Typing;
	DeleteBackward;
	DeleteForward;
	Paste;
	Autocorrect;
	Composition;
}
