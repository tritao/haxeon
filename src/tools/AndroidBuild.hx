package tools;

import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.modules.ModulePath;
import compiler.hl.HlWriter;
import sys.io.File;

/** Builds an Android HLB asset and its persistent hot-reload sidecars. */
class AndroidBuild {
	public static function main():Void {
		var arguments = Sys.args();
		if (arguments.length != 2)
			throw "Usage: haxe -cp src --run tools.AndroidBuild <source.hx> <output.hl>";

		var sourcePath = arguments[0], outputPath = arguments[1], compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.enablePublicationTracking();
		compiler.addSourceRoot("stdlib");
		compiler.update(sourcePath, File.getContent(sourcePath));
		var result = compiler.compile(ModulePath.fromFile(sourcePath));
		File.saveBytes(outputPath, HlWriter.encode(result.module));
		File.saveBytes(sidecar(outputPath, ".hli"), result.runtimeIdentity);
		File.saveContent(sidecar(outputPath, ".entry"), Std.string(result.functionIds.get("main")));
		compiler.acknowledgePublication(result.revision);
		File.saveBytes(sidecar(outputPath, ".hcs"), compiler.exportIdentityState());
		Sys.println('compiled Android asset $sourcePath -> $outputPath');
	}

	static function sidecar(outputPath:String, suffix:String):String {
		return StringTools.endsWith(outputPath, ".hl")
			? outputPath.substr(0, outputPath.length - 3) + suffix
			: outputPath + suffix;
	}
}
