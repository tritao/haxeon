package haxeon.ui.widgets.text;

/** An editing operation that a controlled document owner may consume before widget mutation. */
enum TextEditIntent {
	Insert(text:String);
	Paste(text:String);
	DeleteBackward;
	DeleteForward;
	DeleteWordBackward(macStyle:Bool);
	DeleteWordForward(macStyle:Bool);
}
