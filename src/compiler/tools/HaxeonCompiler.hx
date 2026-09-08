package compiler.tools;

import compiler.Diagnostic.CompileError;

/** Normal command-line entry point for Haxeon compilation. */
class HaxeonCompiler {
	public static function main():Void {
		var request = CompilerArguments.parse(Sys.args());
		try {
			CompilerDriver.compile(request, Sys.println);
		} catch (failure:CompileError) {
			var diagnostic = failure.diagnostic;
			Sys.println(diagnostic.span.file.path + ":" + Std.string(diagnostic.span.start) + ": " + diagnostic.code + ": " + diagnostic.message);
			throw failure;
		}
	}
}
