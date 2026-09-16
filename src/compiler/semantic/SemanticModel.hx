package compiler.semantic;

import compiler.syntax.Ast.AstProgram;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex;
import compiler.types.TypedAst.TypedProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Token;
import compiler.semantic.SemanticIndex.SemanticIndexBuilder;

/** Immutable, revision-bound semantic facts derived from one parsed module. */
class SemanticModel {
	public final revision:Int;
	public final program:AstProgram;
	public final declarations:DeclarationIndex;
	public var index(default, null):SemanticIndex;
	/** Mutable semantic construction state, never published as the query view. */
	public final builder:SemanticIndexBuilder;

	/** Optional partial typed output owned only by a recovered editor model. */
	public var partialTypedProgram:Null<TypedProgram>;

	/** Signature-inferred program retained for reuse by dependent recovery queries. */
	public var recoveredSignatureProgram:Null<AstProgram>;

	public function new(program:AstProgram, source:SourceFile, revision:Int, ?tokens:Array<Token>) {
		this.revision = revision;
		this.program = program;
		this.declarations = DeclarationIndex.forModule(program, source);
		this.builder = new SemanticIndexBuilder(source.path, revision, declarations, tokens == null ? new Lexer(source).tokenize() : tokens);
		this.builder.indexTypeParameterDeclarations(program);
		this.index = builder.view();
		this.partialTypedProgram = null;
		this.recoveredSignatureProgram = null;
	}

	/** Seal construction state before this model is published to the workspace. */
	public function freeze():Void
		index = builder.freeze();
}
