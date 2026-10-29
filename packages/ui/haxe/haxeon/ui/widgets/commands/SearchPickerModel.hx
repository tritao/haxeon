package haxeon.ui.widgets.commands;

/** Application-owned results and selection; the picker owns focus and scrolling. */
interface SearchPickerModel extends haxeon.ui.widgets.collections.ListViewItemMetadata {
	public function query():String;
	public function selectedIndex():Int;
	public function count():Int;
	public function labelAt(index:Int):String;
	public function enabledAt(index:Int):Bool;
	public function setQuery(value:String):Void;
	/** Normalized UiKey/UiModifier values; pageSize is the visible row count. */
	public function navigate(key:Int, modifiers:Int, pageSize:Int):Void;
	public function activate(index:Int):Void;
}
