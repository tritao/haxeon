package pragtical.app;

import pragtical.api.Editor;
import pragtical.plugins.SearchPlugin;

class Host {
	static var editor:Editor = new Editor();
	static var searchPlugin:SearchPlugin = new SearchPlugin(editor);

	public static function activate():Void {
		searchPlugin.activate();
	}

	public static function deactivate():Void {
		searchPlugin.deactivate();
	}

	public static function saveState():String {
		return searchPlugin.saveState();
	}

	public static function restoreState(value:String):Void {
		searchPlugin.restoreState(value);
	}

	public static function runCommand():Int {
		return editor.execute("find");
	}

	public static function cursor():Int {
		return searchPlugin.cursor();
	}

	public static function documentCount():Int {
		return editor.documents.length;
	}

	public static function callbackCount():Int {
		return editor.commands.length;
	}
}

function activate():Void {
	Host.activate();
}

function deactivate():Void {
	Host.deactivate();
}

function saveState():String {
	return Host.saveState();
}

function restoreState(value:String):Void {
	Host.restoreState(value);
}

function runCommand():Int {
	return Host.runCommand();
}

function cursor():Int {
	return Host.cursor();
}

function documentCount():Int {
	return Host.documentCount();
}

function callbackCount():Int {
	return Host.callbackCount();
}

function main():Int {
	return 42;
}
