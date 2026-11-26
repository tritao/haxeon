using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler.CompileResult;
import sys.FileSystem;
import sys.io.File;

/** Executes a reduced compiler regression on the shipped HashLink runtime. */
class GeneratedProgramRunner {
	public static function exitCode(compiled:CompileResult):Int {
		var directory = Sys.getCwd() + "/out/test-tools";
		if (!FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		var path = directory + "/effects-" + StringTools.replace(Std.string(Sys.time()), ".",
			"-") + "-" + Std.random(0x7fffffff) + ".hl";
		File.saveBytes(path, compiled.artifact.hashLink().hashLinkBytes().flatten());
		var status:Int;
		try {
			status = Sys.command(Sys.getEnv("HAXEON_SDK") + "/bin/hl", [path]);
		} catch (error:Dynamic) {
			FileSystem.deleteFile(path);
			throw error;
		}
		FileSystem.deleteFile(path);
		return status;
	}
}
