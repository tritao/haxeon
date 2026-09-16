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
	public final source:SourceFile;
	public final revision:Int;
	public final program:AstProgram;
	public final declarations:DeclarationIndex;
	public var index(default, null):SemanticIndex;
	/** Mutable semantic construction state, never published as the query view. */
	public final builder:SemanticIndexBuilder;
	var sealed:Bool;

	/** Optional partial typed output owned only by a recovered editor model. */
	public var partialTypedProgram(default, set):Null<TypedProgram>;

	/** Signature-inferred program retained for reuse by dependent recovery queries. */
	public var recoveredSignatureProgram(default, set):Null<AstProgram>;

	public var isFrozen(get, never):Bool;

	public function new(program:AstProgram, source:SourceFile, revision:Int, ?tokens:Array<Token>) {
		this.source = source;
		this.revision = revision;
		this.program = program;
		this.declarations = DeclarationIndex.forModule(program, source);
		this.builder = new SemanticIndexBuilder(source.path, revision, declarations, tokens == null ? new Lexer(source).tokenize() : tokens);
		this.builder.indexTypeParameterDeclarations(program);
		this.index = builder.view();
		this.partialTypedProgram = null;
		this.recoveredSignatureProgram = null;
		this.sealed = false;
	}

	/** Seal construction state before this model is published to the workspace. */
	public function freeze():Void {
		if (sealed)
			return;
		index = builder.freeze();
		sealed = true;
	}

	function get_isFrozen():Bool
		return sealed;

	function set_partialTypedProgram(value:Null<TypedProgram>):Null<TypedProgram> {
		if (sealed)
			throw "Semantic model was used after publication";
		return partialTypedProgram = value;
	}

	function set_recoveredSignatureProgram(value:Null<AstProgram>):Null<AstProgram> {
		if (sealed)
			throw "Semantic model was used after publication";
		return recoveredSignatureProgram = value;
	}
}
