import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * Under the live host, the host and the loaded app each declare String, and arrays the runtime creates natively
 * (String.split) carry whichever String was registered first. App code must treat them as its own Array<String>:
 * viewing them, and concatenating them with arrays the app built, as a cold run of the same program does.
 */
class LiveStringArrayMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-string-array-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx";
		File.saveContent(main,
			"class Main {\n"
			+ "  static var status = 1;\n"
			+ "  @:keep public static function start(arguments:String):Void {\n"
			+ "    var parts:Array<String> = \"a,b\".split(\",\");\n"
			+ "    var joined = parts.concat([\"c\"]).concat(\"d,e\".split(\",\"));\n"
			+ "    var back = [\"z\"].concat(parts);\n"
			+ "    status = joined.join(\"\") == \"abcde\" && back.join(\"\") == \"zab\" ? 0 : 2;\n"
			+ "  }\n"
			+ "  @:keep public static function tick():Int return 0;\n"
			+ "  @:keep public static function close():Int return status;\n"
			+ "  @:keep public static function saveState():String return \"\";\n"
			+ "  @:keep public static function restoreState(state:String):Void {}\n"
			+ "  public static function main():Void {}\n"
			+ "}\n");
		var output = root + "/live.hl", host = root + "/live-host.hl";
		CompilerDriver.compile(CompilerArguments.parse([
			"--target=hl",
			"--entry=Main",
			"--root=" + root,
			"--live",
			"--output=" + output,
			main
		]), _ -> {}, new CompilerSession());
		var hostSources = [for (name in FileSystem.readDirectory("src/runtime")) if (StringTools.endsWith(name, ".hx")) "src/runtime/" + name];
		CompilerDriver.compile(CompilerArguments.parse([
			"--target=hl",
			"--entry=tools.LiveHost",
			"--root=src",
			"--output=" + host,
			"src/tools/LiveHost.hx"
		].concat(hostSources)), _ -> {}, new CompilerSession());
		var status = Sys.command(".tools/hashlink/hl", [host, output, "Main", "[]"]);
		expect(status == 0, 'string arrays from the host and the app must concatenate under the live host; it exited with $status');

		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: host-created string arrays concatenate with app string arrays under the live host");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
