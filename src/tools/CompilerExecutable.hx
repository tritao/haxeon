package tools;

import build.AotCompiler;
import build.HashLinkPath;
import haxe.io.Path;

/**
 * The entry point of Haxeon built ahead of time to C (`haxeon-aot`, `build.AotCompiler`): one executable for the CLI and for
 * every role in which the CLI runs the compiler, chosen by the first argument.
 *
 *   haxeon-aot cli ARGUMENTS  the CLI (`tools.HaxeonCli`), which the `haxeon` launcher runs (native/haxeon_main.c)
 *   haxeon-aot serve STATE    a compile server (`compiler.tools.CompilerServer`), as `hl worker.hl STATE`
 *   haxeon-aot lsp            the language server on standard input and output (`LspMain`), as `haxeon lsp`
 *   haxeon-aot lint ...       the lint rules that need the compiler's analysis (`LintMain`), as `haxeon lint` runs them
 *   haxeon-aot ffi-import ... the C and C++ header importer (`FfiImportMain`), as `haxeon ffi import`
 *   haxeon-aot ffi-audit ...  the cross-target C ABI auditor (`FfiAuditMain`), as `haxeon ffi audit`
 *   haxeon-aot ARGUMENTS      one compile (`compiler.tools.HaxeonCompiler`), as `hl compiler.hl ARGUMENTS`
 *
 * The compiler's own arguments are options (`--entry=...`) and source paths, never these words. Under the JIT each role is a
 * bytecode build of its own, so that none starts by compiling the others' code; ahead of time that costs nothing, and one
 * executable is what a release ships. The CLI and the compiler are built from the same sources, so one stamp says whether
 * the executable is current for both.
 */
class CompilerExecutable {
	/** The CLI's bytecode beside the VM, which the native build publishes (`HAXEON_CLI_BYTECODE` in CMakeLists.txt). */
	static inline final CLI_BYTECODE = "haxeon-cli.hl";

	static function main():Void {
		var arguments = Sys.args();
		switch arguments.length == 0 ? "" : arguments[0] {
			case "cli":
				cli(arguments.slice(1));
			case "serve":
				if (arguments.length != 2)
					throw new compiler.core.InternalError("Usage: haxeon-aot serve STATE");
				compiler.tools.CompilerServer.serve(arguments[1]);
			case "lsp":
				Sys.exit(LspMain.run(arguments.slice(1)));
			case "lint":
				Sys.exit(LintMain.run(arguments.slice(1)));
			case "ffi-import":
				Sys.exit(FfiImportMain.run(arguments.slice(1)));
			case "ffi-audit":
				Sys.exit(FfiAuditMain.run(arguments.slice(1)));
			case _:
				Sys.exit(compiler.tools.HaxeonCompiler.run(arguments));
		}
	}

	/**
	 * The CLI, when this executable is current; else the CLI's bytecode on the VM, as the launcher runs it without the executable,
	 * so an edit to the CLI in a checkout never runs an older CLI. The launcher has set the environment the CLI reads (`HAXEON_SDK`).
	 */
	static function cli(arguments:Array<String>):Void {
		var home = build.HaxeonSdk.current();
		if (home != null && AotCompiler.current(home) == null)
			Sys.exit(Sys.command(HashLinkPath.executable(home),
				[Path.join([HashLinkPath.directory(home), CLI_BYTECODE])].concat(arguments)));
		HaxeonCli.run(arguments);
	}
}
