package compiler.types;

import compiler.Ast.AstProgram;

/** Validated global semantic facts for one canonical, assembled program. */
class SemanticProgram {
	public final program:AstProgram;
	public final declarations:DeclarationIndex;

	public static function analyze(program:AstProgram):SemanticProgram {
		var inferred = SignatureInference.inferProgram(program);
		return new SemanticProgram(inferred, DeclarationIndex.validated(inferred));
	}

	function new(program:AstProgram, declarations:DeclarationIndex) {
		this.program = program;
		this.declarations = declarations;
	}
}
