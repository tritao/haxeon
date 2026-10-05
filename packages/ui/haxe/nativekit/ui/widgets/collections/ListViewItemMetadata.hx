package nativekit.ui.widgets.collections;

/** Optional row metadata for lists whose items need names or disabled states. */
interface ListViewItemMetadata {
	function labelAt(index:Int):String;
	function enabledAt(index:Int):Bool;
}
