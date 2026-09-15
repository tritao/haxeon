package compiler.semantic;

import compiler.syntax.Ast.AstProgram;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex;
import compiler.types.TypedAst.TypedProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Token;

/** Immutable, revision-bound semantic facts derived from one parsed module. */
class SemanticModel {
	public final revision:Int;
	public final program:AstProgram;
	public final declarations:DeclarationIndex;
	public final index:SemanticIndex;

	/** Optional partial typed output owned only by a recovered editor model. */
	public var partialTypedProgram:Null<TypedProgram>;

	/** Signature-inferred program retained for reuse by dependent recovery queries. */
	public var recoveredSignatureProgram:Null<AstProgram>;

	public function new(program:AstProgram, source:SourceFile, revision:Int, ?tokens:Array<Token>) {
		this.revision = revision;
		this.program = program;
		this.declarations = DeclarationIndex.forModule(program, source);
		this.index = new SemanticIndex(source.path, revision, declarations, tokens == null ? new Lexer(source).tokenize() : tokens);
		this.partialTypedProgram = null;
		this.recoveredSignatureProgram = null;
	}
}
