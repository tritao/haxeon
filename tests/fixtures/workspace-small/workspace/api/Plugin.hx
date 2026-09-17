package workspace.api;

interface Plugin {
	function activate():Void;
	function deactivate():Void;
}
