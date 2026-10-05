package nativekit.ui.widgets.text;

/** Compatibility entry point for the editor's local Unicode offset map. */
class TextOffsetMap extends nativekit.editorkit.TextOffsetMap {
	public function new(value:String, ?boundaries:Array<Int>) {
		super(value, boundaries);
	}

	public static function countCodepoints(value:String):Int
		return nativekit.editorkit.TextOffsetMap.countCodepoints(value);
}
