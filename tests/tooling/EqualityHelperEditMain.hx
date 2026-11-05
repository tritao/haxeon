import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * Declared equality helpers reached only through another helper (the comparison of a nested value's field
 * type, say) must survive an incremental edit of an unrelated caller. Such a helper used to take the origin of
 * whichever request sorted first, so editing that caller pruned it while the helper calling it was kept.
 */
class EqualityHelperEditMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/equality-helper-edit-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var point = "struct Point implements Equatable { public var x:Int; public var y:Int; public function new(x:Int, y:Int) { this.x = x; this.y = y; } }";
		var shape = "struct Shape implements Equatable { public var point:Point; public function new(point:Point) this.point = point; }";
		var shapes = "class Shapes { public static function same(a:Shape, b:Shape):Bool return haxeon.Equality.equals(a, b); }";
		// Several requests from the edited function, so at least one sorts before the enum's helper.
		function main(literal:Int):String {
			var checks = [
				for (index in 0...8)
					'(haxeon.Equality.equals(new Point($literal, $literal), new Point($literal, $literal)) ? 1 : 0)'
			].join(" + ");
			return "class Main { public static function main():Int {\n"
				+ "var same = Shapes.same(new Shape(new Point(1, 2)), new Shape(new Point(1, 2))) ? 10 : 0;\n"
				+ 'return same + $checks; } }';
		}
		var args = ["--target=hl", "--entry=Main", "--root=" + root];
		var paths = [root + "/Main.hx", root + "/Point.hx", root + "/Shape.hx", root + "/Shapes.hx"];
		File.saveContent(root + "/Point.hx", point);
		File.saveContent(root + "/Shape.hx", shape);
		File.saveContent(root + "/Shapes.hx", shapes);
		var session = new CompilerSession();
		for (literal in [1, 2, 3]) {
			File.saveContent(root + "/Main.hx", main(literal));
			var output = root + "/main.hl";
			CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + output]).concat(paths)), _ -> {}, session);
			var status = Sys.command(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl", [output]);
			if (status != 18)
				throw 'build with literal $literal returned $status, expected 18';
		}
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: nested declared equality helpers survive incremental edits of other callers");
	}
}
