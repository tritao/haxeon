import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import compiler.modules.ModulePath;
import compiler.tools.BootstrapStatus;
import compiler.types.Type.CompilerType;
import sys.io.File;

class Main {
	static function main():Void {
		var arguments = Sys.args();
		if (arguments.length > 0 && arguments[0] == "bootstrap-status") {
			BootstrapStatus.run(arguments.slice(1));
			return;
		}
		var sourcePath = arguments.length > 0 ? arguments[0] : "tests/programs/add.hx";
		var outputPath = arguments.length > 1 ? arguments[1] : "out/program.hl";
		var compiler = new Compiler();
		compiler.registerNative("trace", "std", "sys_print", [CompilerType.TString], CompilerType.TVoid);
		var module = ModulePath.fromFile(sourcePath);
		compiler.update(sourcePath, File.getContent(sourcePath));
		var result = compiler.compile(module);
		File.saveBytes(outputPath, HlWriter.encode(result.module));
		Sys.println('compiled $sourcePath -> $outputPath');
	}
}
