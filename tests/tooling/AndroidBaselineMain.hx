import compiler.Compiler.CompileResult;
import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import haxe.Json;
import haxeon.io.FileTree;
import sys.FileSystem;
import sys.io.File;

using compiler.compilation.BackendArtifact.BackendArtifacts;

/**
 * An Android module's baseline and the edits compiled against it (docs/design/ANDROID_BUILD.md): the build writes the identity
 * state (`--baseline-output`) and the stable ID of `main` (`--entry-id-output`); an edit compiled with `--baseline` patches or
 * reloads the module that state describes, building on the session when the session wrote it and loading it otherwise.
 */
class AndroidBaselineMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/android-baseline-test-" + Std.random(0x3fffffff);
		for (directory in [root, root + "/edit", root + "/cold"])
			FileSystem.createDirectory(directory);
		var main = root + "/Main.hx", module = root + "/app.hl", baseline = module + ".hcs";
		function arguments(output:String, ?from:String):Array<String> {
			var result = [
				"--target=hl",
				"--entry=Main",
				"--root=" + root,
				"--live",
				"--output=" + output,
				"--baseline-output=" + output + ".hcs",
				"--entry-id-output=" + output + ".entry",
				main
			];
			if (from != null)
				result.push("--baseline=" + from);
			return result;
		}
		function compile(output:String, ?from:String, session:CompilerSession, ?messages:Array<String>):CompileResult
			return CompilerDriver.compile(CompilerArguments.parse(arguments(output, from)), message -> {
				if (messages != null)
					messages.push(message);
			}, session);
		function description(output:String):Dynamic
			return Json.parse(File.getContent(output + ".live.json"));

		File.saveContent(main, "function main():Void trace(value());\nfunction value():Int return 1;\n");
		var session = new CompilerSession(), built = compile(module, session);
		expect(FileSystem.exists(baseline), "a build writes its baseline");
		expect(File.getContent(module + ".entry") == Std.string(built.artifact.hashLink().functionIds.get("main")),
			"a build writes the stable ID of main");

		// A body edit against the baseline the session wrote builds on the session and patches the module.
		File.saveContent(main, "function main():Void trace(value());\nfunction value():Int return 2;\n");
		var edit = root + "/edit/app.hl", messages = [], warm = compile(edit, baseline, session, messages);
		expect(messages.indexOf("reusing compiler session") >= 0,
			"an edit against the baseline the session wrote reuses the session");
		expect(!warm.requiresReload && description(edit).patchAvailable == true && FileSystem.exists(edit + ".hlp"),
			"a body edit is a patch");
		expect(warm.baseRevision == built.revision, "the patch applies to the built revision");
		expect(FileSystem.exists(edit + ".hcs"), "an edit writes the baseline that follows it");

		// Another session loads the baseline and compiles the same edit to the same patch.
		var cold = root + "/cold/app.hl", coldMessages = [];
		compile(cold, baseline, new CompilerSession(), coldMessages);
		expect(coldMessages.indexOf("compiling against the baseline " + baseline) >= 0,
			"a session that did not write the baseline loads it");
		expect(File.getBytes(cold + ".hlp").compare(File.getBytes(edit + ".hlp")) == 0,
			"a loaded baseline patches as the session that wrote it does");

		// The device rejected the edit, so the next one is against the build's baseline again, which the session no longer holds.
		File.saveContent(main, "function main():Void trace(value());\nfunction value():Int return 3;\n");
		var retried = [], again = compile(edit, baseline, session, retried);
		expect(retried.indexOf("compiling against the baseline " + baseline) >= 0,
			"a baseline other than the one the session last wrote is loaded");
		expect(again.baseRevision == built.revision && !again.requiresReload,
			"an edit after a rejected one patches the revision the device runs");

		// A changed signature is a reload.
		File.saveContent(main,
			"function main():Void trace(value(2));\nfunction value(scale:Int):Float return scale * 1.5;\n");
		var reload = compile(edit, baseline, session);
		expect(reload.requiresReload && description(edit).requiresReload == true, "a structural edit is a reload");
		expect(File.getContent(edit + ".entry") == Std.string(reload.artifact.hashLink().functionIds.get("main")),
			"a reload carries the stable ID of its main");

		// The host calls main by its ID, with no arguments and no result.
		File.saveContent(main, "function main():Int return 0;\n");
		var rejected:Null<String> = null;
		try
			compile(root + "/wrong.hl", new CompilerSession())
		catch (error:Dynamic)
			rejected = Std.string(error);
		expect(rejected != null && rejected.indexOf("main():Void") >= 0, "an entry the host cannot call is refused");
		expect(!FileSystem.exists(root + "/wrong.hl"), "a refused module is not written");

		var unlive = false;
		try
			CompilerArguments.parse(["--target=hl", "--entry=Main", "--baseline=" + baseline, main])
		catch (_:Dynamic)
			unlive = true;
		expect(unlive, "a baseline requires a live compile");
		FileTree.remove(root);
		Sys.println("Android baseline tests passed");
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;
}
