package pragtical.plugins;

import pragtical.api.Document;
import pragtical.api.Editor;
import pragtical.api.Plugin;
import pragtical.plugins.PluginState;

class SearchPlugin implements Plugin {
	final editor:Editor;
	final state:PluginState;

	public function new(editor:Editor):Void {
		this.editor = editor;
		this.state = new PluginState();
	}

	public function activate():Void {
		editor.open(new Document("notes.txt", state.cursor));
		editor.register("find", () -> {
			return this.find();
		});
	}

	public function deactivate():Void {
		editor.unregister("find");
	}

	public function find():Int {
		state.cursor = state.cursor + 1;
		return state.cursor;
	}

	public function saveState():String {
		if (state.cursor == 4)
			return "cursor:4";
		if (state.cursor == 5)
			return "cursor:5";
		if (state.cursor == 7)
			return "cursor:7";
		if (state.cursor == 10)
			return "cursor:10";
		return "cursor:unknown";
	}

	public function restoreState(value:String):Void {
		if (value == "cursor:4")
			state.cursor = 4;
		if (value == "cursor:5")
			state.cursor = 5;
		if (value == "cursor:7")
			state.cursor = 7;
		if (value == "cursor:10")
			state.cursor = 10;
	}

	public function cursor():Int {
		return state.cursor;
	}
}
