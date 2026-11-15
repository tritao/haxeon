import driver.TestDriver;
import editor.lsp.LspProtocol;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

@:access(driver.TestDriver)
class DriverTemporaryDirectoryMain {
	static function main():Void {
		var first = TestDriver.createTemporaryDirectory();
		var second = TestDriver.createTemporaryDirectory();
		if (first == second)
			throw "Concurrent driver runs share a temporary directory";
		if (!~/^haxeon-test-[0-9]+-[0-9]+$/.match(Path.withoutDirectory(first)))
			throw "Driver directory name must be safe in a file URI";
		var project = Path.join([first, "project"]);
		FileSystem.createDirectory(project);
		File.saveContent(Path.join([project, "haxe.json"]), '{"classPath":["src"],"main":"Main"}');
		FileSystem.createDirectory(Path.join([project, "src"]));
		File.saveContent(Path.join([project, "src", "Main.hx"]), 'function main():Int return 42;');
		var protocol = new LspProtocol();
		var messages = protocol.handle(Json.stringify({
			jsonrpc: "2.0",
			id: 1,
			method: "initialize",
			params: {rootUri: "file://" + project}
		}));
		if (messages.length != 1 || protocol.project.errors.length != 0)
			throw "LSP initialization rejected the driver directory: " + Json.stringify(protocol.project.errors);
		if (Sys.systemName() != "Windows") {
			File.saveContent(second + "/keep", "intact");
			if (Sys.command("ln", ["-s", second, first + "/link"]) != 0)
				throw "Cannot create temporary directory symlink";
		}
		TestDriver.removeTemporaryDirectory(first);
		if (FileSystem.exists(first))
			throw "Driver temporary directory was not removed";
		if (Sys.systemName() != "Windows" && File.getContent(second + "/keep") != "intact")
			throw "Cleanup followed a symlink outside the temporary directory";
		TestDriver.removeTemporaryDirectory(second);
	}
}
