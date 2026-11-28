package compiler.semantic;

import compiler.core.Source.SourceFile;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Lexer;
import compiler.syntax.TokenTable;
import compiler.types.DeclarationIndex;

/** Immutable, revision-bound semantic facts derived from one parsed module. */
class SemanticModel {
	public final revision:Int;
	public final program:AstProgram;
	public final declarations:DeclarationIndex;
	public final index:SemanticIndex;

	/** `module`: the module's name (`ModuleState.name`), which names its symbols. */
	public function new(program:AstProgram, source:SourceFile, module:String, revision:Int, ?tokens:TokenTable) {
		this.revision = revision;
		this.program = program;
		this.declarations = DeclarationIndex.forModule(program, source);
		this.index = new SemanticIndex(module, revision, declarations,
			tokens == null ? new Lexer(source).tokenizeTable() : tokens);
	}
}
