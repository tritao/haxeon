package compiler.tools;

import compiler.core.Diagnostic.CompileError;
import compiler.tools.DiagnosticPrinter.DiagnosticFormat;

/** Normal command-line entry point for Haxeon compilation. */
class HaxeonCompiler {
	public static function main():Void {
		ProcessMemory.oneShotCompile();
		// One compile per process: nothing is kept for a next build.
		var request = CompilerArguments.parse(Sys.args().concat([compiler.CompileOptions.NO_KEEP_SESSION]));
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
			CompilerDriver.compile(request, Sys.println, null, null, null, printed);
		} catch (failure:CompileError) {
			printed(new DiagnosticPrinter(request).errors(failure.diagnostics));
			throw failure;
		}
	}
}
