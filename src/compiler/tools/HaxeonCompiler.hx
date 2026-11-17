package compiler.tools;

import compiler.core.Diagnostic.CompileError;

/** Normal command-line entry point for Haxeon compilation. */
class HaxeonCompiler {
	public static function main():Void {
		var request = CompilerArguments.parse(Sys.args());
		try {
			CompilerDriver.compile(request, Sys.println);
		} catch (failure:CompileError) {
			Sys.println(failure.formatAll());
			throw failure;
		}
	}
}
