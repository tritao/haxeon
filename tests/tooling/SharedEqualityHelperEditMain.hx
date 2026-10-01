import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * A structural equality helper reached from two comparisons is needed by both helpers that call it, though it has
 * the origin of only one request. When that comparison is edited away, the helper must stay while the other
 * comparison's helper still calls it: pruning by origin alone dropped it, and the next verification failed on the
 * unknown `$equality` call (so did every later build in that session until the worker started over).
 */
class SharedEqualityHelperEditMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/shared-equality-helper-edit-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		// Left and Right both contain an Inner, so the helper for Inner is shared by the helpers for Left and Right.
		var files = [
			"Inner.hx" => "typedef Inner = {a:Int, b:Int};",
			"Left.hx" => "typedef Left = {inner:Inner, x:Int};",
			"Right.hx" => "typedef Right = {inner:Inner, y:Int};",
			"P.hx" => "class P { public static function same(a:Left, b:Left):Bool return haxeon.Equality.equals(a, b); }",
			"Q.hx" => "class Q { public static function same(a:Right, b:Right):Bool return haxeon.Equality.equals(a, b); }",
			"Main.hx" => "class Main { public static function main():Int {\n" +
			"var l:Left = {inner: {a: 1, b: 2}, x: 3}; var r:Right = {inner: {a: 1, b: 2}, y: 3}; var other:Right = {inner: {a: 1, b: 9}, y: 3};\n" +
			"return (P.same(l, l) ? 1 : 0) + (Q.same(r, r) ? 10 : 0) + (Q.same(r, other) ? 100 : 0); } }"
		];
		var args = ["--target=hl", "--entry=Main", "--root=" + root, "--output=" + root + "/main.hl"];
		var paths = [for (name in files.keys()) root + "/" + name];
		function build(session:CompilerSession, label:String):Int {
			try {
				CompilerDriver.compile(CompilerArguments.parse(args.concat(paths)), _ -> {}, session);
			} catch (error:Dynamic) {
				throw '$label: ${Std.string(error).split("\n")[0]}';
			}
			return Sys.command(".tools/hashlink/hl", [root + "/main.hl"]);
		}
		// Whichever of the two comparisons has the shared helper's origin, stop comparing in each in turn.
		for (edited in ["P.hx", "Q.hx"]) {
			for (name => text in files)
				File.saveContent(root + "/" + name, text);
			var session = new CompilerSession();
			var first = build(session, '$edited, first build');
			if (first != 11)
				throw '$edited: the first build returned $first, expected 11';
			File.saveContent(root + "/" + edited, StringTools.replace(files.get(edited), "return haxeon.Equality.equals(a, b);", "return true;"));
			// P.same(l, l) is true either way; Q.same(r, other) is false until Q stops comparing.
			var expected = edited == "Q.hx" ? 111 : 11;
			var second = build(session, '$edited stops comparing');
			if (second != expected)
				throw '$edited stops comparing: the build returned $second, expected $expected';
		}
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: an equality helper shared by two comparisons survives an edit of one of them");
	}
}
