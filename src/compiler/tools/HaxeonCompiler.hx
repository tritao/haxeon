package compiler.tools;

import compiler.core.Diagnostic.CompileError;

/** Normal command-line entry point for Haxeon compilation. */
class HaxeonCompiler {
	public static function main():Void {
		ProcessMemory.oneShotCompile();
		// One compile per process: nothing is kept for a next build.
		var request = CompilerArguments.parse(Sys.args().concat([compiler.CompileOptions.NO_KEEP_SESSION]));
		try {
			CompilerDriver.compile(request, Sys.println);
		} catch (failure:CompileError) {
			Sys.println(failure.formatAll());
			throw failure;
		}
	}
}
