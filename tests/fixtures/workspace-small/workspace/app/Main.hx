package workspace.app;

import workspace.api.Editor;
import workspace.plugins.SearchPlugin;

class Host {
	static var editor:Editor = new Editor();
	static var searchPlugin:SearchPlugin = new SearchPlugin(editor);

	public static function activate():Void {
		searchPlugin.activate();
	}

	public static function deactivate():Void {
		searchPlugin.deactivate();
	}

	public static function runCommand():Int {
		var current:Editor = editor;
		return current.execute("find");
	}

	public static function documentCount():Int {
		return editor.documents.length;
	}
}

function activate():Void {
	Host.activate();
}

function deactivate():Void {
	Host.deactivate();
}

function runCommand():Int {
	return Host.runCommand();
}

function documentCount():Int {
	return Host.documentCount();
}

function main():Int {
	return 42;
}
