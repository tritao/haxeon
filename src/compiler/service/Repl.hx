package compiler.service;

import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import haxe.io.Bytes;

typedef ReplProgram = {
	final bytes:Bytes;
	final identity:Bytes;
	final stableId:Int;
}

/** Compiles ephemeral expressions against a persistent compiler snapshot. */
class Repl {
	final compiler:Compiler;

	public function new(compiler:Compiler)
		this.compiler = compiler;

	public function compileInt(expression:String):ReplProgram {
		var result = compiler.compileExpressionInt(expression),
			stableId = result.functionIds.get("main");
		if (stableId == null)
			throw "REPL compilation did not produce a stable entry function";
		return {bytes: HlWriter.encode(result.module), identity: result.runtimeIdentity, stableId: stableId};
	}
}
