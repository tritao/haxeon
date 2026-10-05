package haxeon.ui.widgets.text;

/** Compatibility entry point for the editor's local Unicode offset map. */
class TextOffsetMap extends haxeon.editor.TextOffsetMap {
	public function new(value:String, ?boundaries:Array<Int>) {
		super(value, boundaries);
	}

	public static function countCodepoints(value:String):Int
		return haxeon.editor.TextOffsetMap.countCodepoints(value);
}
