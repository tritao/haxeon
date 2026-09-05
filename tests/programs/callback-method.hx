class Editor {
	public function register(callback:Void->Void):Void {
		callback();
	}
}

class Plugin {
	final editor:Editor;

	public function new(editor:Editor) {
		this.editor = editor;
	}

	public function activate():Void {
		editor.register(() -> {});
	}
}

function main():Int {
	var editor = new Editor();
	var plugin = new Plugin(editor);
	plugin.activate();
	return 42;
}
