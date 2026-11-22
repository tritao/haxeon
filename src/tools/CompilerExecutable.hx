package tools;

/**
 * The entry point of the compiler built ahead of time to C (`haxeon-compiler`, `build.AotCompiler`): one executable for every
 * role in which the CLI runs the compiler, chosen by the first argument.
 *
 *   haxeon-compiler serve STATE   a compile server (`compiler.tools.CompilerServer`), as `hl worker.hl STATE`
 *   haxeon-compiler lsp           the language server on standard input and output (`LspMain`), as `haxeon lsp`
 *   haxeon-compiler ARGUMENTS     one compile (`compiler.tools.HaxeonCompiler`), as `hl compiler.hl ARGUMENTS`
 *
 * The compiler's own arguments are options (`--entry=...`) and source paths, never these words. Under the JIT each role is a
 * bytecode build of its own, so that none starts by compiling the others' code; ahead of time that costs nothing, and one
 * executable is what a release ships.
 */
class CompilerExecutable {
	static function main():Void {
		var arguments = Sys.args();
		switch arguments.length == 0 ? "" : arguments[0] {
			case "serve":
				if (arguments.length != 2)
					throw new compiler.core.InternalError("Usage: haxeon-compiler serve STATE");
				compiler.tools.CompilerServer.serve(arguments[1]);
			case "lsp":
				Sys.exit(LspMain.run(arguments.slice(1)));
			case _:
				compiler.tools.HaxeonCompiler.run(arguments);
		}
	}
}
