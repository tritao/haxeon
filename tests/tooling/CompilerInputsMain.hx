import build.execution.ContentDigest;
import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import haxe.Json;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/**
 * `--inputs-output`: the compile reports the modules it read with the digest of each module's text, and a persistent session
 * notices a new file in an earlier source root that shadows a module it already loaded (the report names the new file).
 */
class CompilerInputsMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/compiler-inputs-test-" + Std.random(0x3fffffff);
		var early = root + "/early",
			late = root + "/late",
			output = root + "/main.hl",
			inputs = root + "/inputs.json";
		FileSystem.createDirectory(root);
		FileSystem.createDirectory(early);
		FileSystem.createDirectory(late);
		var main = late + "/Main.hx",
			value = late + "/Value.hx",
			shadow = early + "/Value.hx";
		File.saveContent(main, "class Main { public static function main():Int { return Value.get(); } }");
		File.saveContent(value, "class Value { public static function get():Int { return 7; } }");
		var session = new CompilerSession();
		function compile():Map<String, Array<String>> {
			CompilerDriver.compile(CompilerArguments.parse([
				"--target=hl",
				"--entry=Main",
				"--root=" + early,
				"--root=" + late,
				"--output=" + output,
				"--inputs-output=" + inputs,
				main
			]), _ -> {}, session);
			var rows:Array<Array<String>> = Json.parse(File.getContent(inputs)),
				byName:Map<String, Array<String>> = [];
			for (row in rows)
				byName.set(row[0], row);
			return byName;
		}
		var first = compile();
		expect(first.exists("Main") && first.exists("Value"), "the report lists the program's modules");
		expect(first.get("Value")[2] == ContentDigest.makeHex(File.getBytes(value)), "the digest is the module text's");
		expect(first.get("Value")[1] == FileSystem.fullPath(value) || StringTools.endsWith(first.get("Value")[1], "/late/Value.hx"),
			"the path is the file read");
		var again = compile();
		expect(again.get("Value")[2] == first.get("Value")[2], "an unchanged compile reports the same digests");
		File.saveContent(value, "class Value { public static function get():Int { return 8; } }");
		expect(compile().get("Value")[2] == ContentDigest.makeHex(File.getBytes(value)), "an edit changes the digest");
		File.saveContent(shadow, "class Value { public static function get():Int { return 9; } }");
		var shadowed = compile().get("Value");
		expect(StringTools.endsWith(shadowed[1], "/early/Value.hx"), "a new file in an earlier root shadows the loaded module in a persistent session");
		expect(shadowed[2] == ContentDigest.makeHex(File.getBytes(shadow)), "the shadowing file's digest is reported");
		Sys.println("Compiler inputs report passed");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
