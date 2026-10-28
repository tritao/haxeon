import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * Under `--strict-live` the host refuses any edit that cannot patch. Two common edits patch: a parameter added to a
 * constructor, and a lambda inserted before its siblings at the same anchor, which renumbers them. Callbacks registered
 * before the edit keep running their own functions.
 */
class LiveStrictSignatureLambdaMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-strict-signature-lambda-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx",
			output = root + "/live.hl",
			host = root + "/live-host.hl";
		function write(edited:Bool):Void
			File.saveContent(main,
				"class Item {\n"
				+ "  public var v:Int;\n"
				+ (edited ? "  public function new(v:Int, w:Int) this.v = v + w;\n" : "  public function new(v:Int) this.v = v;\n")
				+ "}\n"
				+ "class Main {\n"
				+ "  static var ticks = 0;\n"
				+ "  static var handlers:Array<Int->Int> = [];\n"
				+ "  static function register():Void {\n"
				+ (edited ? "    handlers.push(x -> x - 4);\n" : "")
				+ "    handlers.push(x -> x + 1);\n"
				+ "    handlers.push(x -> x * 10);\n"
				+ "  }\n"
				// The edited value is 3 only when the stored handlers still return 2 and 10 and the new constructor ran.
				+ (edited ? "  static function value():Int return handlers[0](1) * 100 + handlers[1](1) == 210 && new Item(1, 2).v == 3 ? 3 : 2;\n" : "  static function value():Int return new Item(1).v;\n")
				+ "  @:keep public static function start(arguments:String):Void register();\n"
				// A host that never applies the edit stops after about 30 s, so the test fails instead of hanging.
				+ "  @:keep public static function tick():Int { Sys.sleep(0.01); return value() == 3 || ++ticks > 3000 ? 0 : 1; }\n"
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
		write(false);
		build(output, "Main", root, [main], true);
		build(host, "tools.LiveHost", "src", ["src/tools/LiveHost.hx"].concat([
			for (name in FileSystem.readDirectory("src/runtime"))
				if (StringTools.endsWith(name, ".hx")) "src/runtime/" + name
		]), false);
		var hl = FileSystem.fullPath(".tools/hashlink/hl" + (Sys.systemName() == "Windows" ? ".exe" : ""));
		Sys.putEnv("HAXEON_LIVE_STRICT", "1");
		var process = new Process(hl, [host, output, "Main", "[]"]);
		Sys.sleep(1.5);
		write(true);
		build(output, "Main", root, [main], true);
		var log = process.stdout.readAll().toString();
		var status = process.exitCode();
		process.close();
		Sys.print(log);
		expect(log.indexOf("LIVE PATCH REFUSED") < 0, "the strict host must not refuse a constructor parameter or a renumbered lambda");
		expect(log.indexOf("patched live module to revision 2") >= 0, "the host must patch the edit");
		expect(log.indexOf("reloading") < 0, "strict mode must not reload the module");
		expect(status == 0, 'stored handlers must keep their functions and the new constructor must run; the host exited with $status');
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a strict live host patches a constructor parameter and a lambda inserted before its siblings");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
