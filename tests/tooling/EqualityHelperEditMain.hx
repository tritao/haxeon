import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * Structural equality helpers reached only through another helper (the comparison of an enum payload's element
 * type, say) must survive an incremental edit of an unrelated caller. Such a helper used to take the origin of
 * whichever request sorted first, so editing that caller pruned it while the helper calling it was kept.
 */
class EqualityHelperEditMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/equality-helper-edit-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var shapes = "enum Shape { Poly(points:Array<{x:Int, y:Int}>); }\n"
			+ "class Shapes { public static function same(a:Shape, b:Shape):Bool return haxeon.Equality.equals(a, b); }";
		// Several requests from the edited function, so at least one sorts before the enum's helper.
		function main(literal:Int):String {
			var checks = [
				for (index in 0...8)
					'(haxeon.Equality.equals({f$index: $literal}, {f$index: $literal}) ? 1 : 0)'
			].join(" + ");
			return "class Main { public static function main():Int {\n"
				+ "var same = Shapes.same(Poly([{x: 1, y: 2}]), Poly([{x: 1, y: 2}])) ? 10 : 0;\n"
				+ 'return same + $checks; } }';
		}
		var args = ["--target=hl", "--entry=Main", "--root=" + root];
		var paths = [root + "/Main.hx", root + "/Shapes.hx"];
		File.saveContent(root + "/Shapes.hx", shapes);
		var session = new CompilerSession();
		for (literal in [1, 2, 3]) {
			File.saveContent(root + "/Main.hx", main(literal));
			var output = root + "/main.hl";
			CompilerDriver.compile(CompilerArguments.parse(args.concat(["--output=" + output]).concat(paths)), _ -> {}, session);
			var status = Sys.command(".tools/hashlink/hl", [output]);
			if (status != 18)
				throw 'build with literal $literal returned $status, expected 18';
		}
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: nested structural equality helpers survive incremental edits of other callers");
	}
}
