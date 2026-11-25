package haxeon.ui.core;

import haxeon.ui.editing.EditorDocument;


/** Stable invocation data shared by menus, shortcuts, palettes, and scripts. */
class CommandContext {
	/** The document the command acts on, if any. */
	public final document:Null<EditorDocument>;

	/** The ids of what is selected in it. */
	public final selection:Array<String>;

	/** The viewport the command was invoked in, if any. */
	public final viewportId:Null<String>;

	/** Arguments a palette, menu item or script passes. */
	public final parameters:CommandParameters;

	/** What invoked the command, as the application names it, for its logs and tracing; ui does not read it. */
	public final source:Null<String>;
	/** Optional application trace hook for inspector edits. */
	public var onPropertyEdit:Null<Dynamic->Void> = null;

	/** Invocation data for a command; everything is optional. */
	public function new(?document:EditorDocument, ?selection:Array<String>,
			?viewportId:String, ?parameters:CommandParameters, ?source:String) {
		this.document = document;
		this.selection = selection == null ? [] : selection.copy();
		this.viewportId = viewportId;
		this.parameters = parameters == null ? new CommandParameters() : parameters;
		this.source = source;
	}

	/** Whether anything is selected. */
	public var hasSelection(get, never):Bool;
	inline function get_hasSelection():Bool
		return selection.length > 0;

	/** Whether `id` is among the selected. */
	public function hasSelected(id:String):Bool
		return id != null && selection.indexOf(id) >= 0;
}
