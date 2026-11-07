import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;
import tools.IdentityPath;

/**
 * `haxeon identity-path`: the import graph the compiler makes identities from (written when `HAXEON_IDENTITY_GRAPH` is set) and
 * the report built from it: shortest path, closure size, direct importers, cycles, unknown modules.
 *
 * Module graph (an arrow is an import): Main -> A, D, E, Z; A -> B -> C; D -> C; Z -> X <-> Y.
 */
class IdentityPathMain {
	static var checks = 0;

	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/identity-path-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var files = [
			"Main" => 'import haxeon.build.CodeIdentity;
class Main {
	static function main():Int {
		Sys.println(CodeIdentity.ofModule("Main"));
		return A.value() + D.value() + E.value() + Z.value() - 12;
	}
}',
			"A" => "class A { public static function value():Int return B.value() + 1; }",
			"B" => "class B { public static function value():Int return C.value() + 1; }",
			"C" => "class C { public static function value():Int return 1; }",
			"D" => "class D { public static function value():Int return C.value() + 2; }",
			"E" => "class E { public static function value():Int return 5; }",
			"X" => "class X { public static function value():Int return 1; public static function viaY():Int return Y.value(); }",
			"Y" => "class Y { public static function value():Int return 2; public static function viaX():Int return X.value(); }",
			"Z" => "class Z { public static function value():Int return X.viaY(); }"
		];
		var names = [for (name in files.keys()) name];
		for (name => text in files)
			File.saveContent(root + "/" + name + ".hx", text);
		var graph = root + "/graph.txt";
		Sys.putEnv("HAXEON_IDENTITY_GRAPH", graph);
		CompilerDriver.compile(CompilerArguments.parse(["--target=hl", "--entry=Main", "--root=" + root, "--output=" + root + "/out.hl"]
			.concat([for (name in names) root + "/" + name + ".hx"])), _ -> {}, new CompilerSession());
		expect(FileSystem.exists(graph), "the compiler wrote the import graph");
		var text = File.getContent(graph);
		var lines = [for (line in text.split("\n")) if (line != "") line];
		// The graph also holds the standard-library modules the program reaches.
		expect(lines.length >= 9, "one line per module: " + lines.length);
		var mainLine = [for (line in lines) if (StringTools.startsWith(line, "Main\t")) line][0];
		expect(mainLine.indexOf("A,D,E") > 0 && mainLine.indexOf("Z") > 0, "Main's imports: " + mainLine);
		expect(lines.indexOf("C\t") >= 0, "a leaf has no imports");
		expect(lines.indexOf("X\tY") >= 0 && lines.indexOf("Y\tX") >= 0, "a cycle is two edges");

		var toC = IdentityPath.report(text, "Main", "C");
		expect(toC.indexOf("covers ") >= 0 && toC.indexOf(" modules (itself included).") > 0, "Main's closure is reported: " + toC);
		expect(toC.indexOf("Shortest import path (2 edges):\n  Main -> D\n  D -> C") >= 0, "shortest path Main to C: " + toC);
		expect(toC.indexOf("import C directly (2):") >= 0 && toC.indexOf("B -> C") >= 0 && toC.indexOf("D -> C") >= 0, "both importers of C: " + toC);
		var fromA = IdentityPath.report(text, "A", "C");
		expect(fromA.indexOf("covers 3 modules") >= 0 && fromA.indexOf("Shortest import path (2 edges):\n  A -> B\n  B -> C") >= 0, "from A: " + fromA);
		expect(IdentityPath.report(text, "A", "E").indexOf("does not depend on E") >= 0, "A does not reach E");
		expect(IdentityPath.report(text, "C", "Main").indexOf("does not depend on Main") >= 0, "a leaf reaches nothing");
		expect(IdentityPath.report(text, "X", "Y").indexOf("Shortest import path (1 edges):\n  X -> Y") >= 0, "cycle, one way");
		expect(IdentityPath.report(text, "Y", "X").indexOf("Shortest import path (1 edges):\n  Y -> X") >= 0, "cycle, the other way");
		expect(IdentityPath.report(text, "Z", "Y").indexOf("covers 3 modules") >= 0, "Z reaches Z, X, Y");
		expect(IdentityPath.report(text, "Nope", "C").indexOf('"Nope" is not in the program') >= 0, "unknown source");
		expect(IdentityPath.report(text, "Main", "Nope").indexOf('"Nope" is not in the program') >= 0, "unknown target");
		expect(IdentityPath.report(text, "Main", "Main").indexOf("0 edges") >= 0, "a module reaches itself in zero edges");

		deleteTree(root);
		Sys.println("PASS: identity-path (" + checks + " checks)");
	}

	static function deleteTree(path:String):Void {
		for (entry in FileSystem.readDirectory(path)) {
			var child = path + "/" + entry;
			if (FileSystem.isDirectory(child))
				deleteTree(child);
			else
				FileSystem.deleteFile(child);
		}
		FileSystem.deleteDirectory(path);
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
		checks++;
	}
}
