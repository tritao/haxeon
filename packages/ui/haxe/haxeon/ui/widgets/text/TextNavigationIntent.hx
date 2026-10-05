package haxeon.ui.widgets.text;

/** Keyboard navigation delegated by a controlled editor with multiple selections. */
enum TextNavigationIntent {
	Character(direction:Int, extend:Bool);
	Word(direction:Int, extend:Bool, macStyle:Bool);
	Paragraph(direction:Int, extend:Bool, macStyle:Bool);
	VisualLine(direction:Int, extend:Bool);
	LineBoundary(end:Bool, extend:Bool);
	DocumentBoundary(end:Bool, extend:Bool);
}
