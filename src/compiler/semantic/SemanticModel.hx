package compiler.semantic;

import compiler.syntax.Ast.AstProgram;
import compiler.Source.SourceFile;
import compiler.types.DeclarationIndex;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedProgram;
import compiler.syntax.Lexer;
import compiler.syntax.Token;
import compiler.service.CancellationToken;
import compiler.semantic.SemanticIndex.SemanticIndexBuilder;
import compiler.semantic.SemanticIndex.SemanticSymbolId;

/** Immutable, revision-bound semantic facts derived from one parsed module. */
class SemanticModel {
	public final source:SourceFile;
	public final revision:Int;
	public final program:AstProgram;
	public final declarations:DeclarationIndex;
	public var index(default, null):SemanticIndex;
	/** Mutable semantic construction state, never published as the query view. */
	var builder:Null<SemanticIndexBuilder>;
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
		var active = constructionBuilder();
		index = active.freeze();
		// No published semantic model should retain the mutable traversal
		// workspace. Recovery identity reuse reads the frozen index below.
		builder = null;
		sealed = true;
	}

	/** Add exact typed-function facts while this model is being constructed. */
	public function indexTypedFunction(fn:TypedFunction, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>, ?token:CancellationToken, ?deferBindingSort = false):Void
		constructionBuilder().indexTypedFunction(fn, resolve, resolveEnumCase, token, deferBindingSort);

	/** Add exact typed field-initializer facts while this model is being constructed. */
	public function indexTypedInitializer(owner:String, expression:TypedExpression, resolve:String->Null<SemanticSymbolId>,
			resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>):Void
		constructionBuilder().indexTypedInitializer(owner, expression, resolve, resolveEnumCase);

	/** Add exact type-reference facts while this model is being constructed. */
	public function indexTypeReferences(resolve:String->Null<SemanticSymbolId>, ?token:CancellationToken):Void
		constructionBuilder().indexTypeReferences(resolve, token);

	/** Add editor-only module declarations to this model's recovery index. */
	public function indexRecoveredModule(program:AstProgram, external:DeclarationIndex, qualifiers:Array<String>, ?token:CancellationToken):Void
		constructionBuilder().indexRecoveredModule(program, external, qualifiers, token);

	/** Add editor-only syntax and partial-typing facts to this model. */
	public function indexRecoveredSyntax(program:AstProgram, ?token:CancellationToken, ?typedProgram:TypedProgram,
			?resolve:String->Null<SemanticSymbolId>, ?resolveEnumCase:(String, Int) -> Null<SemanticSymbolId>,
			?resolveType:(String, Array<compiler.types.Type.CompilerType>) -> Null<compiler.types.Type.CompilerType>,
			?candidates:String->Array<SemanticSymbolId>, ?previous:SemanticModel,
			?resolveTypeSymbol:String->Null<SemanticSymbolId>):Void {
		constructionBuilder().indexRecoveredSyntax(program, token, typedProgram, resolve, resolveEnumCase, resolveType, candidates,
			previous == null ? null : previous.index, resolveTypeSymbol);
	}

	function constructionBuilder():SemanticIndexBuilder {
		var active = builder;
		if (active == null)
			throw "Semantic model was used after publication";
		return active;
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
