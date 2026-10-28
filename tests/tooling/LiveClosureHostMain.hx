import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * A live host given a patch that deletes a lambda the app stored: the runtime refuses it, because the closure would be
 * stranded. A strict host shows the refusal with what holds the closure and keeps running; the default host reloads. An app
 * that rebuilds what holds its handlers (`liveRelease`, `liveRebuild`) takes the same edit as a patch. A hook that throws is
 * the app's error: the host reports it as a warning, and the patch's outcome is what the runtime did.
 */
class LiveClosureHostMain {
	static function main():Void {
		var strict = run(true, "");
		expect(strict.indexOf("LIVE PATCH REFUSED") >= 0, "the strict host must refuse the patch that strands a stored closure");
		expect(strict.indexOf("1 stored closure still references it (held by Main.handlers[0])") >= 0,
			"the strict host must say what holds the stranded closure");
		expect(strict.indexOf("reloading") < 0, "the strict host must not reload");
		var lenient = run(false, "");
		expect(lenient.indexOf("patch rejected; reloading module") >= 0 && lenient.indexOf("held by Main.handlers[0]") >= 0,
			"the default host must reload, saying why");
		var rebuilt = run(true, "rebuild");
		expect(rebuilt.indexOf("patched live module to revision 2") >= 0 && rebuilt.indexOf("LIVE PATCH REFUSED") < 0,
			"a strict host must patch the edit when the app rebuilds what held the closure");
		// A `liveRebuild` that throws after the patch applied: revision 2 runs, the host says so, and the next edit patches it.
		var rebuildThrew = run(true, "throwingRebuild");
		expect(rebuildThrew.indexOf("patched live module to revision 2") >= 0 && rebuildThrew.indexOf("patched live module to revision 3") >= 0,
			"a strict host must keep patching when the app's liveRebuild throws");
		expect(rebuildThrew.indexOf("haxeon: warning: Main.liveRebuild() threw") >= 0, "the host must report the throwing liveRebuild");
		expect(rebuildThrew.indexOf("LIVE PATCH REFUSED") < 0, "a throwing liveRebuild must not refuse the patch");
		// A `liveRelease` that throws after letting go: the patch applies, and `liveRebuild` still runs.
		var releaseThrew = run(true, "throwingRelease");
		expect(releaseThrew.indexOf("patched live module to revision 2") >= 0 && releaseThrew.indexOf("patched live module to revision 3") >= 0,
			"a strict host must patch when the app's liveRelease throws");
		expect(releaseThrew.indexOf("haxeon: warning: Main.liveRelease() threw") >= 0, "the host must report the throwing liveRelease");
		expect(releaseThrew.indexOf("app: rebuilt 1 handler") >= 0, "the host must run liveRebuild after a throwing liveRelease");
		expect(releaseThrew.indexOf("LIVE PATCH REFUSED") < 0, "a throwing liveRelease must not refuse the patch");
		Sys.println("PASS: a live host refuses or reloads a patch that strands a stored closure, and patches it when the app rebuilds its handlers");
	}

	/**
	 * Runs a host on a program that stores two handlers, deletes the first, and returns what the host printed. `hooks` is the
	 * app's: none (""), rebuilding ones ("rebuild"), or rebuilding ones of which `liveRebuild` or `liveRelease` throws
	 * ("throwingRebuild", "throwingRelease"); with throwing ones a third edit follows, which the host must patch too.
	 */
	static function run(strict:Bool, hooks:String):String {
		var root = FileSystem.fullPath(".") + "/out/live-closure-host-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx",
			output = root + "/live.hl",
			host = root + "/live-host.hl",
			stop = StringTools.replace(root + "/stop", "\\", "/");
		function write(handlers:Array<String>):Void
			File.saveContent(main,
				"class Main {\n"
				+ "  static var ticks = 0;\n"
				+ "  static var handlers:Array<Int->Int> = [];\n"
				+ "  static function register():Void {\n"
				+ [for (handler in handlers) '    handlers.push($handler);\n'].join("")
				+ "  }\n"
				+ "  @:keep public static function start(arguments:String):Void register();\n"
				+ (hooks == "" ? "" : "  @:keep public static function liveRelease():Void {\n    handlers = [];\n"
					+ (hooks == "throwingRelease" ? "    throw \"release failed\";\n" : "") + "  }\n"
					+ "  @:keep public static function liveRebuild():Void {\n    register();\n"
					+ "    Sys.println(\"app: rebuilt \" + handlers.length + \" handler\");\n"
					+ (hooks == "throwingRebuild" ? "    throw \"rebuild failed\";\n" : "") + "  }\n")
				// About 30 s at most, so a host that never applies the edit fails the test instead of hanging it.
				+ "  @:keep public static function tick():Int { Sys.sleep(0.01); return sys.FileSystem.exists(\"" + stop
				+ "\") || ++ticks > 3000 ? 0 : 1; }\n"
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
		write(["x -> x + 1", "x -> x * 10"]);
		build(output, "Main", root, [main], true);
		build(host, "tools.LiveHost", "src", ["src/tools/LiveHost.hx"].concat([
			for (name in FileSystem.readDirectory("src/runtime"))
				if (StringTools.endsWith(name, ".hx")) "src/runtime/" + name
		]), false);
		var hl = FileSystem.fullPath(".tools/hashlink/hl" + (Sys.systemName() == "Windows" ? ".exe" : ""));
		Sys.putEnv("HAXEON_LIVE_STRICT", strict ? "1" : "0");
		var process = new Process(hl, [host, output, "Main", "[]"]);
		Sys.sleep(1.5);
		write(["x -> x * 10"]);
		build(output, "Main", root, [main], true);
		Sys.sleep(2.5);
		if (StringTools.startsWith(hooks, "throwing")) {
			write(["x -> x * 20"]);
			build(output, "Main", root, [main], true);
			Sys.sleep(2.5);
		}
		File.saveContent(stop, "");
		var log = process.stdout.readAll().toString();
		process.exitCode();
		process.close();
		Sys.print(log);
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		return log;
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
