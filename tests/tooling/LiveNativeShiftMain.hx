import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * A live session appends to its function slots, but the runtime natives come first in the slot order, so
 * the first use of a runtime native moves every function up by one. The published object method tables
 * must move with them: the module has to run exactly as a cold build of the same source does.
 */
class LiveNativeShiftMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-native-shift-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx";
		var shape = "class Box { final v:Int; public function new(v:Int) this.v = v; public function get():Int return v; public function twice():Int return v * 2; public function negated():Int return -v; }\n"
			+ "class Loud extends Box { public function new(v:Int) super(v); override public function twice():Int return v * 3; }\n";
		var first = shape
			+
			"class Main { public static function main():Int { var box:Box = Std.random(1) == 0 ? new Box(20) : new Loud(20); return box.get() + box.twice() + box.negated(); } }";
		// The same program, now also formatting a float: the first use of a string conversion native.
		var second = shape
			+
			"class Main { public static function main():Int { var box:Box = Std.random(1) == 0 ? new Box(20) : new Loud(20); var text = \"\" + 1.5; return box.get() + box.twice() + box.negated() + text.length; } }";
		var args = ["--target=hl", "--entry=Main", "--root=" + root];

		function compile(session:CompilerSession, source:String, extra:Array<String>, name:String):String {
			File.saveContent(main, source);
			var output = root + "/" + name + ".hl";
			CompilerDriver.compile(CompilerArguments.parse(args.concat(extra).concat(["--output=" + output, main])), _ -> {}, session);
			return output;
		}
		function run(output:String):Int {
			return Sys.command(".tools/hashlink/hl", [output]);
		}

		var expected = run(compile(new CompilerSession(), second, [], "cold"));
		expect(expected == 20 + 40 - 20 + 3, 'the cold build of the second revision must return 43, got $expected');

		for (mode in [[], ["--live"]]) {
			var label = mode.length == 0 ? "artifact" : "live";
			var session = new CompilerSession();
			expect(run(compile(session, first, mode, label + "-first")) == 40, "the first revision must return 40");
			var actual = run(compile(session, second, mode, label + "-second"));
			expect(actual == expected, '$label: the incremental build of the second revision returned $actual, a cold build returns $expected');
		}

		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a new runtime native does not leave stale method slots in a live module");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
