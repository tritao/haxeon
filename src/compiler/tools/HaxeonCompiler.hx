package compiler.tools;

import compiler.core.Diagnostic.CompileError;
import compiler.core.UsageError;
import compiler.tools.DiagnosticPrinter.DiagnosticFormat;

/** Normal command-line entry point for Haxeon compilation. */
class HaxeonCompiler {
	public static function main():Void {
		ProcessMemory.oneShotCompile();
		// One compile per process: nothing is kept for a next build.
		var request:CompilerRequest;
		try
			request = CompilerArguments.parse(Sys.args().concat([compiler.CompileOptions.NO_KEEP_SESSION]))
		catch (error:UsageError) {
			Sys.stderr().writeString("haxeon compiler: " + error.message + "\n");
			Sys.exit(2);
			return;
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
			printed(new DiagnosticPrinter(request).errors(failure.diagnostics));
			throw failure;
		}
	}
}
