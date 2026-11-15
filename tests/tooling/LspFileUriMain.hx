import editor.lsp.DocumentStore;
import editor.lsp.LspProtocol;
import editor.lsp.ProjectWorkspace;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class LspFileUriMain {
	static function main():Void {
		var parent = Sys.getEnv("TMPDIR");
		if (parent == null || parent == "")
			throw "TMPDIR is required";
		var root = Path.join([parent, "lsp-C++ café-" + Std.random(1000000000)]);
		FileSystem.createDirectory(Path.join([root, "src"]));
		File.saveContent(Path.join([root, "haxe.json"]), '{"classPath":["src"],"main":"Main"}');
		var source = Path.join([root, "src", "Main.hx"]);
		File.saveContent(source, 'function main():Int return 42;');
		var uriRoot = "file://" + StringTools.replace(StringTools.replace(root, " ", "%20"), "é", "%C3%A9");
		var uri = uriRoot + "/src/Main.hx";
		if (new DocumentStore().open(uri, 1, "").path != source)
			throw "Document file URI decoded incorrectly";
		if (new DocumentStore().open(StringTools.replace(uri, "+", "%2B"), 1, "").path != source)
			throw "Percent-encoded plus decoded incorrectly";
		if (ProjectWorkspace.pathFromUri(uri) != StringTools.replace(FileSystem.absolutePath(source), "\\", "/"))
			throw "Workspace file URI decoded incorrectly";
		var protocol = new LspProtocol();
		var messages = protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			id: 1,
			method: "initialize",
			params: {rootUri: uriRoot}
		}));
		if (messages.length != 1 || protocol.project.errors.length != 0 || protocol.project.configurations.length != 1)
			throw "Workspace initialization failed for encoded file URI: " + Json.stringify(protocol.project.errors);
		FileSystem.deleteFile(source);
		FileSystem.deleteDirectory(Path.join([root, "src"]));
		FileSystem.deleteFile(Path.join([root, "haxe.json"]));
		FileSystem.deleteDirectory(root);
	}
}
