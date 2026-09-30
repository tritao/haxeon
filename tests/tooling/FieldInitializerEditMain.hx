import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * Editing an instance field initializer must reach the program in an incremental build. The initializer is typed
 * as part of the constructor, so the edit is reported as a change to `new`, but the expression is stored in the
 * field: an incremental build that only swaps method bodies kept running the old initializer.
 */
class FieldInitializerEditMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/field-initializer-edit-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var tool = "class Tool { public final flute:Int; public final shank:Int; public function new(flute:Int, shank:Int) { this.flute = flute; this.shank = shank; } }";
		var base = "class Base { public function new() {} }";
		var main = "class Main { public static function main():Int { var router = new Router(); return router.tool.flute + router.tool.shank; } }";
		var shapes = [
			"explicit constructor with a base class" => (literal:String) ->
				'class Router extends Base { public final tool = new Tool($literal); public function new() { super(); } }',
			"explicit constructor without a base class" => (literal:String) ->
				'class Router { public final tool = new Tool($literal); public function new() {} }',
			"implicit constructor with a base class" => (literal:String) -> 'class Router extends Base { public final tool = new Tool($literal); }',
			"implicit constructor without a base class" => (literal:String) -> 'class Router { public final tool = new Tool($literal); }'
		];
		var args = ["--target=hl", "--entry=Main", "--root=" + root];
		var paths = [for (name in ["Main", "Router", "Tool", "Base"]) root + "/" + name + ".hx"];
		function write(router:String):Void {
			File.saveContent(root + "/Main.hx", main);
			File.saveContent(root + "/Tool.hx", tool);
			File.saveContent(root + "/Base.hx", base);
			File.saveContent(root + "/Router.hx", router);
		}
		function build(session:CompilerSession, name:String):Int {
			var output = root + "/" + name + ".hl";
			CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + output]).concat(paths)), _ -> {}, session);
			return Sys.command(".tools/hashlink/hl", [output]);
		}
		for (shape => router in shapes) {
			var session = new CompilerSession();
			write(router("6, 22"));
			expect(build(session, "first") == 28, '$shape: the first build must return 28');
			// Same-length and different-length edits, then an edit back.
			for (literal => expected in ["6, 15" => 21, "61, 150" => 211, "6, 22" => 28]) {
				write(router(literal));
				var actual = build(session, "edited");
				expect(actual == expected, '$shape: after editing the initializer to ($literal) the incremental build returned $actual, expected $expected');
			}
		}
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: edits to instance field initializers reach incremental builds");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
