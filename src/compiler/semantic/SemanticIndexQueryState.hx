package compiler.semantic;

import compiler.Source.SourceSpan;
import compiler.service.CancellationToken;
import compiler.types.Type.CompilerType;
import compiler.semantic.SemanticIndex.SemanticCallEdge;
import compiler.semantic.SemanticIndex.SemanticCompletionContext;
import compiler.semantic.SemanticIndex.SemanticCompletionLocal;
import compiler.semantic.SemanticIndex.SemanticIndexBuilder;
import compiler.semantic.SemanticIndex.SemanticSignatureInfo;
import compiler.semantic.SemanticIndex.SemanticSymbolId;
import compiler.semantic.SemanticIndex.IndexedSemanticSymbol;
import compiler.semantic.SemanticIndex.UnresolvedSymbol;
import compiler.semantic.SemanticIndex.ResolvedSemanticReference;

private typedef QueryPositionBinding = {
	final span:SourceSpan;
	final symbol:SemanticSymbolId;
}

/**
	Immutable query data detached from semantic construction state.

	The builder remains responsible for producing this state. Once created,
	queries read only copied maps and arrays, so publication cannot expose the
	mutable traversal workspace used during analysis.
*/
@:allow(compiler.semantic.SemanticIndexBuilder)
class SemanticIndexQueryState {
	public final revision:Int;
	public final indexingMs:Float;
	final symbols:Map<String, IndexedSemanticSymbol>;
	final bindings:Array<QueryPositionBinding>;
	final references:Map<String, Array<SourceSpan>>;
	final signatures:Map<String, SemanticSignatureInfo>;
	final callEdges:Array<SemanticCallEdge>;
	final resolvedReferences:Array<ResolvedSemanticReference>;
	final completionLocals:Array<SemanticCompletionLocal>;
	final completionTypes:Array<{span:SourceSpan, type:CompilerType}>;
	final declarationTypes:Map<SemanticSymbolId, CompilerType>;
	final unresolved:Array<UnresolvedSymbol>;
	final typeParameterIds:Map<String, SemanticSymbolId>;
	/**
		Read-only recovery facts and compatibility providers for algorithms still
		being extracted from the construction builder.
	*/
	final recoveryQuery:SemanticIndexRecoveryQuery;

	private function new(builder:SemanticIndexBuilder) {
		if (!builder.isFrozen)
			throw "Semantic query state requires a frozen recovery query";
		recoveryQuery = new SemanticIndexRecoveryQuery(builder);
		revision = builder.revision;
		indexingMs = builder.indexingMs;
		symbols = builder.symbols.copy();
		bindings = [for (binding in builder.bindings) {span: binding.span, symbol: binding.symbol}];
		references = [];
		for (id => spans in builder.references)
			references.set(id, spans.copy());
		signatures = [];
		for (id => signature in builder.signatures)
			signatures.set(id, {
				label: signature.label,
				parameters: signature.parameters.copy(),
				result: signature.result
			});
		callEdges = [for (edge in builder.callEdges) {caller: edge.caller, callee: edge.callee, span: edge.span}];
		resolvedReferences = [for (reference in builder.resolvedReferences) {
			owner: reference.owner,
			target: reference.target,
			targetId: reference.targetId,
			kind: reference.kind
		}];
		completionLocals = [for (local in builder.completionLocals) {
			name: local.name,
			type: local.type,
			declaration: local.declaration,
			scope: local.scope,
			depth: local.depth
		}];
		completionTypes = [for (completion in builder.completionTypes) {
			span: completion.span,
			type: completion.type
		}];
		declarationTypes = [];
		for (id => type in builder.declarationTypes)
			declarationTypes.set(id, type);
		unresolved = [for (symbol in builder.unresolved)
			{name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()}];
		typeParameterIds = [];
		for (key => id in builder.typeParameterIds)
			typeParameterIds.set(key, id);
	}

	static function fromBuilder(builder:SemanticIndexBuilder):SemanticIndexQueryState
		return new SemanticIndexQueryState(builder);

	public function snapshotSymbols():Map<String, IndexedSemanticSymbol>
		return symbols.copy();

	public function symbolIdAt(position:Int, ?token:CancellationToken):Null<SemanticSymbolId> {
		var selected:Null<QueryPositionBinding> = null;
		for (binding in bindings) {
			if (token != null)
				token.check();
			if (position < binding.span.start || position > binding.span.end)
				continue;
			var width = binding.span.end - binding.span.start,
				selectedWidth = selected == null ? 0x3fffffff : selected.span.end - selected.span.start;
			if (selected == null || width < selectedWidth
				|| width == selectedWidth && binding.span.start > selected.span.start)
				selected = binding;
		}
		return selected == null ? null : selected.symbol;
	}

	public function symbolAt(position:Int):Null<IndexedSemanticSymbol> {
		var id = symbolIdAt(position);
		return id == null ? null : symbols.get(id);
	}

	public function symbol(id:SemanticSymbolId):Null<IndexedSemanticSymbol>
		return symbols.get(id);

	public function signature(id:SemanticSymbolId):Null<SemanticSignatureInfo>
		return copySignature(signatures.get(id));

	public function typeParameterId(owner:String, name:String):Null<SemanticSymbolId>
		return typeParameterIds.get(SemanticIndexBuilder.typeParameterKey(owner, name));

	public function calls():Array<SemanticCallEdge>
		return [for (edge in callEdges) {caller: edge.caller, callee: edge.callee, span: edge.span}];

	public function resolvedDependencies():Array<ResolvedSemanticReference>
		return [for (reference in resolvedReferences) {
			owner: reference.owner,
			target: reference.target,
			targetId: reference.targetId,
			kind: reference.kind
		}];

	public function locations(id:SemanticSymbolId):Array<SourceSpan> {
		var result = references.get(id);
		return result == null ? [] : result.copy();
	}

	public function unresolvedSymbols():Array<UnresolvedSymbol>
		return [for (symbol in unresolved)
			{name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()}];

	public function unresolvedAt(position:Int):Null<UnresolvedSymbol> {
		for (symbol in unresolved)
			if (position >= symbol.span.start && position <= symbol.span.end)
				return {name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()};
		return null;
	}

	public function typeAt(position:Int, ?token:CancellationToken):Null<CompilerType> {
		var symbol = symbolIdAt(position, token);
		if (symbol != null && declarationTypes.exists(symbol))
			return declarationTypes.get(symbol);
		var result:Null<CompilerType> = null, width = 0x3fffffff;
		for (candidate in completionTypes) {
			if (token != null)
				token.check();
			if (position >= candidate.span.start && position <= candidate.span.end && candidate.span.end - candidate.span.start < width) {
				result = candidate.type;
				width = candidate.span.end - candidate.span.start;
			}
		}
		for (local in completionLocals) {
			if (token != null)
				token.check();
			if (position >= local.declaration.start && position <= local.declaration.end)
				return local.type;
		}
		if (result != null)
			return result;
		return symbol == null ? null : declarationTypes.get(symbol);
	}

	/** Recovery query compatibility while the shared algorithms are extracted. */
	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext
		return recoveryQuery.completionContext(position, qualifier, token);

	public function recoveredSignature(name:String, ?receiverType:CompilerType):Null<SemanticSignatureInfo>
		return recoveryQuery.recoveredSignature(name, receiverType);

	public function callableSignature(type:Null<CompilerType>, name:String):Null<SemanticSignatureInfo>
		return recoveryQuery.callableSignature(type, name);

	static function copySignature(signature:Null<SemanticSignatureInfo>):Null<SemanticSignatureInfo>
		return signature == null ? null : {
			label: signature.label,
			parameters: signature.parameters.copy(),
			result: signature.result
		};
}
