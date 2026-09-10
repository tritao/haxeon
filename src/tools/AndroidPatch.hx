package tools;

import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.runtime.CompilerIntrinsics;
import compiler.modules.ModulePath;
import sys.FileSystem;
import sys.io.File;

/** Compiles one source edit against the Android compiler baseline. */
class AndroidPatch {
	public static function main():Void {
		var arguments = Sys.args();
		if (arguments.length != 3)
			throw "Usage: haxe -cp src --run tools.AndroidPatch <source.hx> <baseline.hcs> <output.hlp>";

		var sourcePath = FileSystem.fullPath(arguments[0]),
			statePath = arguments[1],
			patchPath = arguments[2],
			compiler = new Compiler(File.getBytes(statePath), CompilerIntrinsics.configuration());
		compiler.addSourceRoot("stdlib");
		compiler.update(sourcePath, File.getContent(sourcePath));
		var result:CompileResult = compiler.compile(ModulePath.fromFile(sourcePath));
		if (result.requiresReload)
			throw "Android edit requires a domain reload; only compatible body edits can be sent as HLP";
		if (result.patchBytes == null)
			throw "Android edit did not produce an HLP patch";

		File.saveBytes(patchPath, result.patchBytes);
		compiler.acknowledgePublication(result.revision);
		File.saveBytes(statePath + ".pending", compiler.exportIdentityState());
		Sys.println('compiled Android patch revision ${result.revision} (${result.patchBytes.length} bytes) -> $patchPath (baseline pending device acknowledgement)');
	}
}
