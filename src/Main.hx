import compiler.CompileOptions;
import compiler.Compiler;
import compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import haxe.io.Path;
import sys.io.File;

/** Command-line compiler entry point for producing a complete HashLink module. */
class Main {
	static function main():Void
		compileRequest(Sys.args());

	static function compileRequest(arguments:Array<String>):Void {
		// `--plain` builds as `haxeon build` does: not for live patching, so what nothing reaches is not in the module.
		var plain = arguments.indexOf("--plain") >= 0;
		// The passes and self-checks (`--no-inline`, `--no-early-prune`, `--check-reuse`, ...) are this request's alone.
		var options = CompileOptions.fromArguments(arguments);
		arguments = [
			for (argument in arguments)
				if (argument != "--plain" && !CompileOptions.isFlag(argument)) argument
		];
		var sourcePath = arguments.length > 0 ? arguments[0] : "tests/programs/add.hx";
		var outputPath = arguments.length > 1 ? arguments[1] : "out/program.hl";
		var directory = Path.directory(sourcePath);
		var module = ModulePath.fromFile(Path.withoutDirectory(sourcePath));
		var compiler = newCompiler(plain, directory, options);
		compiler.update(sourcePath, File.getContent(sourcePath), module);
		var result = compiler.compile(module);
		// Warnings go to stderr, as `haxeon build` reports them (CompilerDriver).
		for (warning in compiler.warnings(result.moduleNames))
			Sys.stderr().writeString(warning.format() + "\n");
		File.saveBytes(outputPath,
			BackendArtifacts.hashLinkBytes(BackendArtifacts.hashLink(result.artifact)).flatten());
		Sys.println('compiled $sourcePath -> $outputPath');
	}

	static function newCompiler(plain:Bool, directory:String, options:CompileOptions):Compiler {
		var compiler = new Compiler();
		compiler.livePatching = !plain;
		compiler.options = options;
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		// Modules the file refers to are found beside it, as with `-cp .` in Haxe.
		compiler.addSourceRoot(directory == "" ? "." : directory);
		return compiler;
	}

}
