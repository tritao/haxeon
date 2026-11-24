package compiler.tools;

import compiler.core.Diagnostic.CompileError;
import compiler.core.UsageError;
import compiler.tools.DiagnosticPrinter.DiagnosticFormat;

/** Normal command-line entry point for Haxeon compilation. */
class HaxeonCompiler {
	public static function main():Void
		Sys.exit(run(Sys.args()));

	/**
	 * Compiles once with the compiler's command-line `arguments` (`CompilerArguments`), in a process that then exits with the
	 * returned status: 0, 1 when the compile fails, 2 for a usage error.
	 */
	public static function run(arguments:Array<String>):Int {
		ProcessMemory.oneShotCompile();
		// One compile per process: nothing is kept for a next build.
		var request:CompilerRequest;
		try
			request = CompilerArguments.parse(arguments.concat([compiler.CompileOptions.NO_KEEP_SESSION]))
		catch (error:UsageError) {
			Sys.stderr().writeString("haxeon compiler: " + error.message + "\n");
			return 2;
		}
		var full = request.diagnosticFormat == DiagnosticFormat.Full;
		// The full format is for people, on standard error; the short one stays on standard output, where tools read it.
		function printed(text:String):Void {
			if (full) {
				Sys.stdout().flush();
				Sys.stderr().writeString(text + "\n");
			} else
				Sys.println(text);
		}
		try {
			if (request.noOutput)
				CompilerDriver.check(request, Sys.println, null, null, printed);
			else
				CompilerDriver.compile(request, Sys.println, null, null, null, printed);
		} catch (failure:CompileError) {
			// The diagnostics are the whole report: a failed compile is not a crash, so it gets no exception trace.
			printed(new DiagnosticPrinter(request).errors(failure.diagnostics));
			return 1;
		}
		return 0;
	}
}
