import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * Code identities (`haxeon.build.CodeIdentity.ofModule`): editing a module changes its identity and its dependants' and
 * nothing else; clean and incremental builds agree; builds are deterministic; the compiler version and the defines are part of
 * every identity; import cycles share one identity.
 *
 * Module graph (an arrow is an import): Main -> A, D, E, Z; A -> B -> C; D -> C; Z -> X <-> Y.
 */
class CodeIdentityMain {
	static var root = "";
	static var checks = 0;
	static final all = ["Main", "A", "B", "C", "D", "E", "X", "Y", "Z"];

	static function sources(edits:Map<String, String>):Map<String, String> {
		var files = [
			"Main" => 'import haxeon.build.CodeIdentity;
class Main {
	static function main():Int {
		var seen = [A.value(), D.value(), E.value(), Z.value()];
		for (name in ["Main", "A", "B", "C", "D", "E", "X", "Y", "Z", "Nope"])
			Sys.println(name + "=" + CodeIdentity.ofModule(name));
		return seen.length - 4;
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
		for (name => text in edits)
			files.set(name, text);
		return files;
	}

	static function write(files:Map<String, String>):Void
		for (name => text in files)
			File.saveContent(root + "/" + name + ".hx", text);

	static function build(session:CompilerSession, tag:String, ?extra:Array<String>):Map<String, String> {
		var output = root + "/" + tag + ".hl";
		var args = ["--target=hl", "--entry=Main", "--root=" + root, "--output=" + output].concat(extra == null ? [] : extra);
		CompilerDriver.compile(CompilerArguments.parse(args.concat([for (name in all) root + "/" + name + ".hx"])), _ -> {}, session);
		var process = new Process(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl", [output]);
		var text = process.stdout.readAll().toString();
		var code = process.exitCode();
		process.close();
		expect(code == 0, '$tag: the program exited with $code: $text');
		var identities = new Map<String, String>();
		for (line in text.split("\n")) {
			var cut = line.indexOf("=");
			if (cut > 0)
				identities.set(line.substr(0, cut), line.substr(cut + 1));
		}
		return identities;
	}

	static function changed(before:Map<String, String>, after:Map<String, String>):String {
		var names = [for (name in all) if (before.get(name) != after.get(name)) name];
		return names.join(",");
	}

	static function sameAll(a:Map<String, String>, b:Map<String, String>, message:String):Void
		expect(changed(a, b) == "", '$message: differs in ' + changed(a, b));

	static function main():Void {
		root = FileSystem.fullPath(".") + "/out/code-identity-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var base = sources([]);
		write(base);
		var session = new CompilerSession();
		var first = build(session, "first");
		for (name in all)
			expect(first.get(name) != null && first.get(name) != "null" && first.get(name).length == 32, 'identity of $name: ${first.get(name)}');
		expect(first.get("Nope") == "null", "an unknown module has no identity");
		var distinct = new Map<String, Bool>();
		for (name in all)
			distinct.set(first.get(name), true);
		expect(first.get("X") == first.get("Y"), "modules of an import cycle share one identity");
		expect([for (_ in distinct) 1].length == all.length - 1, "every other module has its own identity");

		// Editing a leaf changes it and everything that depends on it, and nothing else.
		write(sources(["C" => "class C { public static function value():Int return 11; }"]));
		var editedC = build(session, "c");
		expect(changed(first, editedC) == "Main,A,B,C,D", "editing C changed " + changed(first, editedC));
		// A comment-only edit is an edit too: the identity is of the source, not of the compiled code.
		write(sources(["C" => "// note\nclass C { public static function value():Int return 11; }"]));
		var commented = build(session, "c-comment");
		expect(changed(editedC, commented) == "Main,A,B,C,D", "a comment edit changed " + changed(editedC, commented));
		// Editing back restores the original identities exactly.
		write(base);
		sameAll(first, build(session, "c-back"), "editing C back");

		// A module nothing else of this graph imports changes only itself and its importers.
		write(sources(["E" => "class E { public static function value():Int return 6; }"]));
		var editedE = build(session, "e");
		expect(changed(first, editedE) == "Main,E", "editing E changed " + changed(first, editedE));
		write(base);
		build(session, "e-back");

		// A middle module: its dependants change, its dependencies do not.
		write(sources(["B" => "class B { public static function value():Int return C.value() + 20; }"]));
		var editedB = build(session, "b");
		expect(changed(first, editedB) == "Main,A,B", "editing B changed " + changed(first, editedB));
		write(base);
		build(session, "b-back");

		// Editing one member of a cycle changes the whole cycle and its importers.
		write(sources(["Y" => "class Y { public static function value():Int return 3; public static function viaX():Int return X.value(); }"]));
		var editedY = build(session, "y");
		expect(changed(first, editedY) == "Main,X,Y,Z", "editing Y changed " + changed(first, editedY));
		expect(editedY.get("X") == editedY.get("Y"), "the cycle still shares one identity");
		write(base);
		build(session, "y-back");

		// A long sequence of edits in one session ends where a clean build of the same sources does.
		write(sources(["C" => "class C { public static function value():Int return 3; }", "E" => "class E { public static function value():Int return 9; }"]));
		build(session, "seq1");
		write(sources(["A" => "class A { public static function value():Int return B.value() + 4; }", "Y" => "class Y { public static function value():Int return 7; public static function viaX():Int return X.value(); }"]));
		build(session, "seq2");
		var finalSources = sources(["C" => "class C { public static function value():Int return 3; }", "D" => "class D { public static function value():Int return 0; }",
			"A" => "class A { public static function value():Int return B.value() + 4; }", "E" => "class E { public static function value():Int return 9; }"]);
		write(finalSources);
		var incremental = build(session, "seq3");
		var clean = build(new CompilerSession(), "clean");
		sameAll(incremental, clean, "incremental versus clean build of the same sources");
		sameAll(clean, build(new CompilerSession(), "clean-again"), "two clean builds of the same sources");

		// The compiler version and the defines are part of every identity.
		write(base);
		var v1 = build(new CompilerSession(), "v1", ["--define=compiler-version=1"]);
		var v1again = build(new CompilerSession(), "v1b", ["--define=compiler-version=1"]);
		var v2 = build(new CompilerSession(), "v2", ["--define=compiler-version=2"]);
		sameAll(v1, v1again, "the same compiler version");
		expect(changed(v1, v2) == all.join(","), "a new compiler version changes every identity: " + changed(v1, v2));
		var defined = build(new CompilerSession(), "d1", ["--define=compiler-version=1", "--define=feature=on"]);
		expect(changed(v1, defined) == all.join(","), "a define changes every identity: " + changed(v1, defined));
		// A session carries the version across edits and rebuilds with a new one.
		var sessionV = new CompilerSession();
		sameAll(v1, build(sessionV, "sv1", ["--define=compiler-version=1"]), "a session build with the version");
		expect(changed(v1, build(sessionV, "sv2", ["--define=compiler-version=2"])) == all.join(","), "a session rebuild with a new compiler version");

		deleteTree(root);
		Sys.println("PASS: code identities (" + checks + " checks)");
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
