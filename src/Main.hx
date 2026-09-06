import compiler.hl.HlWriter;
import compiler.Compiler;
import compiler.modules.ModulePath;
import compiler.runtime.RuntimeAbi;
import sys.io.File;

/** Command-line compiler entry point for producing a complete HashLink module. */
class Main {
	static function main():Void {
		var arguments = Sys.args();
		var sourcePath = arguments.length > 0 ? arguments[0] : "tests/programs/add.hx";
		var outputPath = arguments.length > 1 ? arguments[1] : "out/program.hl";
		var compiler = new Compiler();
		RuntimeAbi.register(compiler);
		var module = ModulePath.fromFile(sourcePath);
		compiler.update(sourcePath, File.getContent(sourcePath));
		var result = compiler.compile(module);
		File.saveBytes(outputPath, HlWriter.encode(result.module));
		Sys.println('compiled $sourcePath -> $outputPath');
	}
}
