package compiler.semantic;

import compiler.syntax.Ast.AstProgram;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex;

/** Immutable, revision-bound semantic facts derived from one parsed module. */
class SemanticModel {
	public final revision:Int;
	public final program:AstProgram;
	public final declarations:DeclarationIndex;

	public function new(program:AstProgram, source:SourceFile, revision:Int) {
		this.revision = revision;
		this.program = program;
		this.declarations = DeclarationIndex.forModule(program, source);
	}
}
