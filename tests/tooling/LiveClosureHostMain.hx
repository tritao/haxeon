import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * A live host given a patch that deletes a lambda the app stored: the runtime refuses it, because the closure would be
 * stranded. A strict host shows the refusal with what holds the closure and keeps running; the default host reloads. An app
 * that rebuilds what holds its handlers (`liveRelease`, `liveRebuild`) takes the same edit as a patch.
 */
class LiveClosureHostMain {
	static function main():Void {
		var strict = run(true, false);
		expect(strict.indexOf("LIVE PATCH REFUSED") >= 0, "the strict host must refuse the patch that strands a stored closure");
		expect(strict.indexOf("1 stored closure still references it (held by Main.handlers[0])") >= 0,
			"the strict host must say what holds the stranded closure");
		expect(strict.indexOf("reloading") < 0, "the strict host must not reload");
		var lenient = run(false, false);
		expect(lenient.indexOf("patch rejected; reloading module") >= 0 && lenient.indexOf("held by Main.handlers[0]") >= 0,
			"the default host must reload, saying why");
		var rebuilt = run(true, true);
		expect(rebuilt.indexOf("patched live module to revision 2") >= 0 && rebuilt.indexOf("LIVE PATCH REFUSED") < 0,
			"a strict host must patch the edit when the app rebuilds what held the closure");
		Sys.println("PASS: a live host refuses or reloads a patch that strands a stored closure, and patches it when the app rebuilds its handlers");
	}

	/** Runs a host on a program that stores two handlers, deletes the first, and returns what the host printed. */
	static function run(strict:Bool, rebuilds:Bool):String {
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
				+ (rebuilds ? "  @:keep public static function liveRelease():Void handlers = [];\n"
					+ "  @:keep public static function liveRebuild():Void register();\n" : "")
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
