package compiler.service;

import compiler.Compiler;
import compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.core.InternalError;
import haxe.io.Bytes;

/** Ephemeral wrapper module and generated function used for one REPL expression. */
typedef ReplProgram = {
	final bytes:Bytes;
	final identity:Bytes;

	/** The function that evaluates the expression, which a host finds by name in the module it loads (`Runtime.functionId`). */
	final entry:String;
}

/** Compiles ephemeral expressions against a persistent compiler snapshot. */
class Repl {
	final compiler:Compiler;

	static inline final ENTRY = "main";

	public function new(compiler:Compiler)
		this.compiler = compiler;

	public function compileInt(expression:String):ReplProgram {
		var result = BackendArtifacts.hashLink(compiler.compileExpressionInt(expression).artifact);
		if (!result.functionIndices.exists(ENTRY))
			throw new InternalError("REPL compilation did not produce its entry function");
		return {
			bytes: BackendArtifacts.hashLinkBytes(result).flatten(),
			identity: result.runtimeIdentity,
			entry: ENTRY
		};
	}
}
