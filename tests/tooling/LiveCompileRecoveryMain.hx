import compiler.tools.CompilerServer;
import compiler.tools.CompilerServerProtocol;
import sys.FileSystem;
import sys.io.File;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Thread;

/**
 * A compile error in a live session keeps the session's history: a typo saved right after a good edit, then its fix, patches
 * the module the host runs, with the same identity, without the history the server records once it is idle.
 */
class LiveCompileRecoveryMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-compile-recovery-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var statePath = root + "/server.json", main = root + "/Main.hx", output = root + "/live.hl";
		Thread.create(() -> CompilerServer.serve(statePath));
		var deadline = Sys.time() + 30;
		while (!FileSystem.exists(statePath) && Sys.time() < deadline)
			Sys.sleep(0.01);
		expect(FileSystem.exists(statePath), "the server must publish its state file");
		var server = CompilerServerProtocol.decodeState(File.getContent(statePath));
		expect(server != null, "the server's state must be readable");
		function request(value:CompilerServerRequest):Int {
			var socket = new Socket();
			socket.connect(new Host("127.0.0.1"), server.port);
			CompilerServerProtocol.writeRequest(socket.output, server.token, value);
			var status = -1;
			while (status < 0)
				switch CompilerServerProtocol.readResponse(socket.input) {
					case Status(code):
						status = code;
					case Message(_) | Diagnostics(_):
				}
			socket.close();
			return status;
		}
		function build(body:String):Int {
			File.saveContent(main,
				'class Main {
				@:keep public static function tick():Int return $body;
				public static function main():Void {}
			}');
			return request(Compile([
				"--target=hl",
				"--entry=Main",
				"--root=" + root,
				"--live",
				"--output=" + output,
				main
			]));
		}
		expect(build("1") == 0 && build("2") == 0, "the good edits must compile");
		var published:Dynamic = haxe.Json.parse(File.getContent(output + ".live.json"));
		expect(published.patchAvailable == true, "the good edit must publish a patch");
		expect(build("typo") != 0, "the typo must fail compilation");
		expect(File.getContent(output + ".live.stamp") == published.moduleIdentity + ":" + published.revision,
			"the typo must leave the good edit published");
		expect(build("3") == 0, "the fixed edit must compile");
		expect(!FileSystem.exists(output + ".live.state"), "recovery must use the history still in the server");
		var fixed:Dynamic = haxe.Json.parse(File.getContent(output + ".live.json"));
		expect(fixed.moduleIdentity == published.moduleIdentity && fixed.baseRevision == published.revision
			&& fixed.patchAvailable == true && fixed.requiresReload == false,
			"the fixed edit must patch the last good publication");
		request(Shutdown);
		deadline = Sys.time() + 30;
		while (FileSystem.exists(statePath) && Sys.time() < deadline)
			Sys.sleep(0.01);
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a fixed edit patches the last good live publication");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition) {
			Sys.stderr().writeString("FAIL: " + message + "\n");
			Sys.exit(1);
		}
	}
}
