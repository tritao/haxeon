import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * `--strict-live` refuses an edit that cannot patch, and the app keeps the revision it runs. The refused revision must not
 * break the session: the next build patches the running revision, refused edits included. A build that needs a fresh layout
 * keeps numbering the module's revisions instead of starting over. A build from a new compiler session, which has none of
 * the running module's history, is refused too instead of reloading.
 */
class LiveStrictRefusalMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-strict-refusal-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx",
			output = root + "/live.hl",
			host = root + "/live-host.hl",
			stop = root + "/stop";
		function write(value:Int, extraGlobal:Bool):Void
			File.saveContent(main,
				"class Main {\n"
				+ "  static var ticks = 0;\n"
				+ (extraGlobal ? "  static var counted:Int = 0;\n" : "")
				+ "  static function value():Int return " + value + ";\n"
				+ "  @:keep public static function start(arguments:String):Void {}\n"
				// The app stops once it runs revision 3 and the test is done; a host that never applies the edit stops after about
				// 30 s, so the test fails instead of hanging.
				+ "  @:keep public static function tick():Int { Sys.sleep(0.01); " + (extraGlobal ? "counted++; " : "")
				+ "return value() == 3 && sys.FileSystem.exists(\"" + StringTools.replace(stop, "\\", "/") + "\") || ++ticks > 3000 ? 0 : 1; }\n"
				+ "  @:keep public static function close():Int return 0;\n"
				+ "  @:keep public static function saveState():String return \"\";\n"
				+ "  @:keep public static function restoreState(state:String):Void {}\n"
				+ "  public static function main():Void {}\n"
				+ "}\n");
		var session = new CompilerSession();
		function build(path:String, entry:String, rootDirectory:String, sources:Array<String>, live:Bool):Void
			CompilerDriver.compile(CompilerArguments.parse(["--target=hl", "--entry=" + entry, "--root=" + rootDirectory, "--output="
				+ path].concat(live ? ["--live"] : []).concat(sources)),
				_ -> {}, live ? session : new CompilerSession());
		function revision():Int {
			var description:Dynamic = Json.parse(File.getContent(output + ".live.json"));
			return description.revision;
		}
		write(1, false);
		build(output, "Main", root, [main], true);
		build(host, "tools.LiveHost", "src", ["src/tools/LiveHost.hx"].concat([
			for (name in FileSystem.readDirectory("src/runtime"))
				if (StringTools.endsWith(name, ".hx")) "src/runtime/" + name
		]), false);
		var hl = FileSystem.fullPath(".tools/hashlink/hl" + (Sys.systemName() == "Windows" ? ".exe" : ""));
		Sys.putEnv("HAXEON_LIVE_STRICT", "1");
		var process = new Process(hl, [host, output, "Main", "[]"]);
		Sys.sleep(1.5);
		// A new static variable is a global the running module cannot take, so the build reloads and strict mode refuses it.
		write(2, true);
		build(output, "Main", root, [main], true);
		var refusedRevision = revision();
		var waited = 0;
		while (!FileSystem.exists(output + ".live.refused") && waited++ < 2000)
			Sys.sleep(0.01);
		expect(FileSystem.exists(output + ".live.refused"), "the strict host must record the refusal for the compiler");
		var record = File.getContent(output + ".live.refused");
		// Undoing the global and editing again patches the revision the host still runs.
		write(3, false);
		build(output, "Main", root, [main], true);
		var patchedRevision = revision();
		var summary:Dynamic = Json.parse(File.getContent(output + ".live.patch.json"));
		var consumed = !FileSystem.exists(output + ".live.refused");
		Sys.sleep(1.5);
		// A new compiler session (a crashed worker's replacement, say) has a module identity of its own and cannot patch.
		write(4, false);
		if (FileSystem.exists(output + ".live.state"))
			FileSystem.deleteFile(output + ".live.state");
		CompilerDriver.compile(CompilerArguments.parse(["--target=hl", "--entry=Main", "--root=" + root, "--output=" + output, "--live", main]), _ -> {},
			new CompilerSession());
		Sys.sleep(1.5);
		File.saveContent(stop, "");
		var log = process.stdout.readAll().toString();
		var status = process.exitCode();
		process.close();
		Sys.print(log);
		expect(refusedRevision == 2, 'a build that needs a fresh layout must keep numbering revisions; it was revision $refusedRevision');
		expect(StringTools.endsWith(record, ":1:2"), 'the refusal record must name the running and the refused revision: $record');
		expect(consumed, "the compiler must consume the refusal record");
		expect(patchedRevision == 3, 'the build after the refusal must take a new revision; it was revision $patchedRevision');
		expect(summary.baseRevision == 1, 'the build after the refusal must patch the running revision 1, not ${summary.baseRevision}');
		expect(log.split("LIVE PATCH REFUSED").length == 3, "the host must refuse the edit that cannot patch and the new session's build, and nothing else");
		expect(log.indexOf("the compiler no longer has the history of the running module") >= 0,
			"the host must say why it refuses the new session's build");
		expect(!FileSystem.exists(output + ".live.refused"), "a build the compiler cannot fix must not leave a refusal record");
		expect(log.indexOf("patched live module to revision 3") >= 0, "the host must patch the edit after the refusal");
		expect(log.indexOf("reloading") < 0, "strict mode must not reload the module");
		expect(status == 0, 'the host must exit cleanly after applying the edit; it exited with $status');
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a strict live host refuses an edit, patches the next one against the revision it runs, and refuses a new compiler session's build");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
