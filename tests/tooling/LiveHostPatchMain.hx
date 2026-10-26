import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** A running live host applies an edit published after it started, from the small patch summary, without reloading. */
class LiveHostPatchMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-host-patch-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx", output = root + "/live.hl", host = root + "/live-host.hl";
		function write(value:Int):Void
			File.saveContent(main,
				"class Main {\n"
				+ "  static var ticks = 0;\n"
				+ "  static function value():Int return " + value + ";\n"
				+ "  @:keep public static function start(arguments:String):Void {}\n"
				// A host that never applies the edit stops after about 30 s, so the test fails instead of hanging.
				+ "  @:keep public static function tick():Int { Sys.sleep(0.01); return value() == 2 || ++ticks > 3000 ? 0 : 1; }\n"
				+ "  @:keep public static function close():Int return 0;\n"
				+ "  @:keep public static function saveState():String return \"\";\n"
				+ "  @:keep public static function restoreState(state:String):Void {}\n"
				+ "  public static function main():Void {}\n"
				+ "}\n");
		var session = new CompilerSession();
		function build(path:String, entry:String, rootDirectory:String, sources:Array<String>, live:Bool):Void
			CompilerDriver.compile(CompilerArguments.parse(["--target=hl", "--entry=" + entry, "--root=" + rootDirectory, "--output=" + path]
				.concat(live ? ["--live"] : []).concat(sources)), _ -> {}, live ? session : new CompilerSession());
		write(1);
		build(output, "Main", root, [main], true);
		build(host, "tools.LiveHost", "src", ["src/tools/LiveHost.hx"].concat([
			for (name in FileSystem.readDirectory("src/runtime"))
				if (StringTools.endsWith(name, ".hx")) "src/runtime/" + name
		]), false);
		var hl = FileSystem.fullPath(".tools/hashlink/hl" + (Sys.systemName() == "Windows" ? ".exe" : ""));
		var process = new Process(hl, [host, output, "Main", "[]"]);
		Sys.sleep(1.5);
		write(2);
		build(output, "Main", root, [main], true);
		var summarized = FileSystem.exists(output + ".live.patch.json");
		var log = process.stdout.readAll().toString();
		var status = process.exitCode();
		process.close();
		Sys.print(log);
		expect(summarized, "the edit must publish a patch summary for the host to read");
		expect(status == 0,'the host must exit cleanly after applying the edit; it exited with $status');
		expect(log.indexOf("patched live module") >= 0, "the host must patch the edit in place");
		expect(log.indexOf("reloading") < 0, "the edit must not reload the module");
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a running live host patches an edit from the summary");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
