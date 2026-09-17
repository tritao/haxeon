package workspace.plugins;

import workspace.api.Editor;
import workspace.api.Plugin;
import workspace.model.Document;

class SearchPlugin implements Plugin {
	final editor:Editor;
	final state:PluginState;

	public function new(editor:Editor):Void {
		this.editor = editor;
		this.state = new PluginState();
	}

	public function activate():Void {
		editor.open(new Document("notes.txt", "searchable notes"));
		editor.register("find", () -> {
			return this.find();
		});
	}

	public function deactivate():Void {}

	public function find():Int {
		var matches = editor.search.find("notes");
		if (matches == 0)
			return state.cursor;
		var current:PluginState = state;
		current.cursor = current.cursor + 1;
		return current.cursor;
	}
}
