import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * A build's bytes must depend on the source alone, however many revisions the persistent session compiled first.
 * Live sessions are the exception on purpose: their function slots, symbol indices and stable ids are append-only
 * so a running module can be patched, and a removed function keeps its slot.
 */
class ArtifactBuildMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/artifact-build-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx";
		var finalSource = "class Main { public static function main():Int { return \"aa\".length; } }";
		// Intermediate revision: a new method of the same class and a new string constant.
		var intermediateSource = "class Main { public static function main():Int { return \"bbbbbbbb\".length + extra(); } static function extra():Int { return 3; } }";
		File.saveContent(main, finalSource);
		var args = ["--target=hl", "--entry=Main", "--root=" + root];

		function compile(session:CompilerSession, extra:Array<String>, name:String):{bytes:haxe.io.Bytes, functions:String} {
			var output = root + "/" + name + ".hl";
			CompilerDriver.compile(CompilerArguments.parse(args.concat(extra).concat(["--output=" + output, main])), _ -> {}, session);
			return {bytes: File.getBytes(output), functions: File.getContent(output + ".functions")};
		}
		function history(extra:Array<String>, name:String):{bytes:haxe.io.Bytes, functions:String} {
			var session = new CompilerSession();
			compile(session, extra, name + "-first");
			File.saveContent(main, intermediateSource);
			var changed = compile(session, extra, name + "-changed");
			expect(changed.functions.indexOf("\tMain.extra\n") >= 0, "the intermediate revision must build the added function");
			File.saveContent(main, finalSource);
			return compile(session, extra, name + "-reverted");
		}

		var cold = compile(new CompilerSession(), [], "cold");
		expect(cold.functions.indexOf("\tMain.extra\n") < 0, "the final source has no extra method");

		// Artifact mode (the default): the history leaves no trace.
		var artifact = history([], "artifact");
		expect(artifact.functions == cold.functions,
			"artifact builds must not keep functions from earlier revisions: " + firstDifference(cold.functions, artifact.functions));
		expect(artifact.bytes.compare(cold.bytes) == 0, "artifact bytes must equal a cold build of the same source");

		// Repeating the same compile changes nothing either.
		var again = compile(new CompilerSession(), [], "cold-again");
		expect(again.bytes.compare(cold.bytes) == 0, "a cold build must be reproducible");

		// Live mode keeps its append-only history: that is what patches address the running module by.
		File.saveContent(main, finalSource);
		var live = history(["--live"], "live");
		expect(live.functions.indexOf("\tMain.extra\n") >= 0, "a live session keeps the slot of a removed function");
		expect(live.bytes.compare(cold.bytes) != 0, "a live session's module carries its history");

		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: artifact builds depend only on the source; live sessions keep their history");
	}

	static function firstDifference(expected:String, actual:String):String {
		var left = expected.split("\n"), right = actual.split("\n");
		for (index in 0...Std.int(Math.max(left.length, right.length)))
			if (left[index] != right[index])
				return 'line ${index + 1}: expected "${left[index]}", got "${right[index]}" (${left.length} vs ${right.length} lines)';
		return "identical";
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
