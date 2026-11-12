import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import haxe.io.Path;
import sys.io.File;

/** Command-line compiler entry point for producing a complete HashLink module. */
class Main {
	static function main():Void {
		var arguments = Sys.args();
		// `--plain` builds as `haxeon build` does: not for live patching, so what nothing reaches is not in the module.
		var plain = arguments.indexOf("--plain") >= 0;
		// `--early-prune` also prunes at the prune point of the pipeline (`IrEntryPrune`), which a plain build does not do by default yet.
		if (arguments.indexOf("--early-prune") >= 0)
			Sys.putEnv("HAXEON_EARLY_PRUNE", "1");
		// `--warm-edit` builds the program, edits it twice in the same session and rebuilds, and checks each rebuild against a fresh
		// compiler's build of the edited source; the output is the last rebuild. It implies a plain build, the only kind that reuses.
		var warmEdit = arguments.indexOf("--warm-edit") >= 0;
		arguments = [
			for (argument in arguments)
				if (argument != "--plain" && argument != "--warm-edit" && argument != "--early-prune") argument
		];
		var sourcePath = arguments.length > 0 ? arguments[0] : "tests/programs/add.hx";
		var outputPath = arguments.length > 1 ? arguments[1] : "out/program.hl";
		var directory = Path.directory(sourcePath);
		var module = ModulePath.fromFile(Path.withoutDirectory(sourcePath));
		if (warmEdit) {
			warmEditBuild(sourcePath, outputPath, directory, module);
			return;
		}
		var compiler = newCompiler(plain, directory);
		compiler.update(sourcePath, File.getContent(sourcePath), module);
		var result = compiler.compile(module);
		File.saveBytes(outputPath, HlWriter.encode(result.module).flatten());
		Sys.println('compiled $sourcePath -> $outputPath');
	}

	static function newCompiler(plain:Bool, directory:String):Compiler {
		var compiler = new Compiler();
		compiler.livePatching = !plain;
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		// Modules the file refers to are found beside it, as with `-cp .` in Haxe.
		compiler.addSourceRoot(directory == "" ? "." : directory);
		return compiler;
	}

	/**
	 * Warm-rebuild coverage for every program: build it, add a function nothing reaches, rebuild in the same session, add a kept
	 * function (so the module changes) and rebuild, then put both inside the file and rebuild again. Each rebuild must be the bytes of a fresh compiler's build of the same text;
	 * with HAXEON_CHECK_REUSE=1 the compiler also compares what it reused with what it would have built, and throws on a difference.
	 */
	static function warmEditBuild(sourcePath:String, outputPath:String, directory:String, module:String):Void {
		var original = File.getContent(sourcePath),
			compiler = newCompiler(true, directory);
		compiler.update(sourcePath, original, module);
		compiler.compile(module);
		var unused = "\nfunction __warmEditUnused():Int return 1;\n";
		var last:Null<haxe.io.Bytes> = null;
		// The third edit lands inside the file, after the last top-level closing brace before the middle of the file, so the declarations before it keep their ranges and the ones
		// after it move: both kinds of function must come out as a fresh build has them.
		var kept = "@:keep function __warmEditKept():Int return 424242;\n",
			cut = original.lastIndexOf("\n}\n", Std.int(original.length / 2));
		var inside = cut < 0 ? original + unused + kept : original.substr(0, cut + 3) + unused + kept + original.substr(cut + 3);
		var edits = [original + unused, original + unused + kept, inside];
		for (editIndex in 0...edits.length) {
			var edited = edits[editIndex];
			compiler.update(sourcePath, edited, module);
			// A session asked to build again registers its source roots again, which is what makes it build rather than return its last result.
			compiler.addStandardLibrarySourceRoot("stdlib");
			compiler.addSourceRoot(directory == "" ? "." : directory);
			var warm = HlWriter.encode(compiler.compile(module).module).flatten();
			var fresh = newCompiler(true, directory);
			fresh.update(sourcePath, edited, module);
			if (warm.compare(HlWriter.encode(fresh.compile(module).module).flatten()) != 0)
				throw 'a warm rebuild of $sourcePath differs from a fresh build of the same text (edit ${editIndex + 1}: ${["a function nothing reaches, appended", "a kept function, appended", "functions inside the file"][editIndex]})';
			last = warm;
		}
		File.saveBytes(outputPath, last);
		Sys.println('compiled $sourcePath (warm edit rebuilds) -> $outputPath');
	}
}
