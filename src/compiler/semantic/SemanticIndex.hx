package compiler.semantic;

import compiler.Source.SourceSpan;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.Type.CompilerType;
import compiler.service.CancellationToken;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.SemanticIndexBuilder;

abstract SemanticSymbolId(String) from String to String {
	public inline function new(module:String, declaration:String)
		this = module + ":" + declaration;
}

typedef IndexedSemanticSymbol = {
	final id:SemanticSymbolId;
	final name:String;
	final kind:DeclarationKind;
	final declaration:SourceSpan;
}

private typedef PositionBinding = {final span:SourceSpan; final symbol:SemanticSymbolId;}

typedef SemanticRecoveredTypeParameterScope = {
	final name:String;
	final owner:String;
	final span:SourceSpan;
}

typedef SemanticCompletionLocal = {
	final name:String;
	final type:CompilerType;
	final declaration:SourceSpan;
	final scope:SourceSpan;
	final depth:Int;
}

enum SemanticCompletionContextKind {
	Expression;
	Member;
	Type;
	Argument;
	Import;
	ObjectField;
	Override;
	Pattern;
}

typedef SemanticCompletionContext = {
	final locals:Array<SemanticCompletionLocal>;
	final typeParameters:Array<String>;
	final receiver:Null<CompilerType>;
	final expected:Null<CompilerType>;
	final kind:SemanticCompletionContextKind;
}

typedef UnresolvedSymbol = {
	final name:String;
	final span:SourceSpan;
	final candidates:Array<SemanticSymbolId>;
}

typedef SemanticSignatureInfo = {
	final label:String;
	final parameters:Array<String>;
	final result:String;
}

typedef SemanticCallEdge = {
	final caller:SemanticSymbolId;
	final callee:SemanticSymbolId;
	final span:SourceSpan;
}

/** Dependency on a declaration established from a successfully typed node. */
typedef ResolvedSemanticReference = {
	final owner:String;
	final target:String;
	final targetId:SemanticSymbolId;
	final kind:SemanticDependencyKind;
}

/**
 * Frozen query facade for one semantic revision. Construction is deliberately
 * unavailable here; callers must obtain a SemanticIndexBuilder and publish it
 * with SemanticIndexBuilder.freeze().
 */
@:allow(compiler.semantic.SemanticIndexBuilder)
class SemanticIndex {
	/** Construction-only access. Null after publication. */
	final construction:Null<SemanticIndexBuilder>;
	final queryState:Null<SemanticIndexQueryState>;

	public var revision(get, never):Int;
	public var symbols(get, never):Map<String, IndexedSemanticSymbol>;
	public var indexingMs(get, never):Float;

	private function new(builder:SemanticIndexBuilder, ?queryState:SemanticIndexQueryState) {
		this.construction = queryState == null ? builder : null;
		this.queryState = queryState;
	}

	function activeConstruction():SemanticIndexBuilder {
		var builder = construction;
		if (builder == null)
			throw "Published semantic index has no construction state";
		return builder;
	}

	function get_revision():Int
		return queryState == null ? activeConstruction().revision : queryState.revision;

	function get_symbols():Map<String, IndexedSemanticSymbol>
		return queryState == null ? activeConstruction().snapshotSymbols() : queryState.snapshotSymbols();

	function get_indexingMs():Float
		return queryState == null ? activeConstruction().indexingMs : queryState.indexingMs;

	public function symbolIdAt(position:Int, ?token:CancellationToken):Null<SemanticSymbolId> {
		if (queryState != null)
			return queryState.symbolIdAt(position, token);
		var builder = activeConstruction();
		var selected:Null<PositionBinding> = null;
		for (binding in builder.bindings) {
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
		if (queryState != null)
			return queryState.symbolAt(position);
		var id = symbolIdAt(position);
		return id == null ? null : activeConstruction().symbols.get(id);
	}

	public function symbol(id:SemanticSymbolId):Null<IndexedSemanticSymbol>
		return queryState == null ? activeConstruction().symbols.get(id) : queryState.symbol(id);

	public function signature(id:SemanticSymbolId):Null<SemanticSignatureInfo>
		return queryState == null ? copySignature(activeConstruction().signatures.get(id)) : queryState.signature(id);

	public function typeParameterId(owner:String, name:String):Null<SemanticSymbolId>
		return queryState == null
			? activeConstruction().typeParameterIds.get(SemanticIndexBuilder.typeParameterKey(owner, name))
			: queryState.typeParameterId(owner, name);

	public function calls():Array<SemanticCallEdge> {
		if (queryState != null)
			return queryState.calls();
		var builder = activeConstruction();
		if (!builder.isFrozen)
			builder.completeCallEdges();
		return [for (edge in builder.callEdges) {caller: edge.caller, callee: edge.callee, span: edge.span}];
	}

	public function resolvedDependencies():Array<ResolvedSemanticReference>
		return queryState == null ? [for (reference in activeConstruction().resolvedReferences) {
			owner: reference.owner,
			target: reference.target,
			targetId: reference.targetId,
			kind: reference.kind
		}] : queryState.resolvedDependencies();

	public function dependsOnAny(ids:Map<String, Bool>):Bool
		return queryState == null ? activeConstruction().dependsOnAny(ids) : queryState.dependsOnAny(ids);

	public function hasUnresolvedName(names:Map<String, Bool>):Bool
		return queryState == null ? activeConstruction().hasUnresolvedName(names) : queryState.hasUnresolvedName(names);

	public function locations(id:SemanticSymbolId):Array<SourceSpan> {
		if (queryState != null)
			return queryState.locations(id);
		var result = activeConstruction().references.get(id);
		return result == null ? [] : result.copy();
	}

	public function completionContext(position:Int, ?qualifier:String, ?token:CancellationToken):SemanticCompletionContext
		return queryState == null
			? activeConstruction().completionContext(position, qualifier, token)
			: queryState.completionContext(position, qualifier, token);

	public function unresolvedSymbols():Array<UnresolvedSymbol>
		return queryState == null ? [for (symbol in activeConstruction().unresolved)
			{name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()}] : queryState.unresolvedSymbols();

	public function unresolvedAt(position:Int):Null<UnresolvedSymbol> {
		if (queryState != null)
			return queryState.unresolvedAt(position);
		for (symbol in activeConstruction().unresolved)
			if (position >= symbol.span.start && position <= symbol.span.end)
				return {name: symbol.name, span: symbol.span, candidates: symbol.candidates.copy()};
		return null;
	}

	public function typeAt(position:Int, ?token:CancellationToken):Null<CompilerType> {
		if (queryState != null)
			return queryState.typeAt(position, token);
		var builder = activeConstruction();
		var symbol = symbolIdAt(position, token);
		if (symbol != null && builder.declarationTypes.exists(symbol))
			return builder.declarationTypes.get(symbol);
		var result:Null<CompilerType> = null, width = 0x3fffffff;
		for (candidate in builder.completionTypes) {
			if (token != null)
				token.check();
			if (position >= candidate.span.start && position <= candidate.span.end && candidate.span.end - candidate.span.start < width) {
				result = candidate.type;
				width = candidate.span.end - candidate.span.start;
			}
		}
		for (local in builder.completionLocals) {
			if (token != null)
				token.check();
			if (position >= local.declaration.start && position <= local.declaration.end)
				return local.type;
		}
		if (result != null)
			return result;
		return symbol == null ? null : builder.declarationTypes.get(symbol);
	}

	public function recoveredSignature(name:String, ?receiverType:CompilerType):Null<SemanticSignatureInfo>
		return queryState == null
			? copySignature(activeConstruction().recoveredSignature(name, receiverType))
			: queryState.recoveredSignature(name, receiverType);

	public function callableSignature(type:Null<CompilerType>, name:String):Null<SemanticSignatureInfo>
		return queryState == null
			? copySignature(activeConstruction().callableSignature(type, name))
			: queryState.callableSignature(type, name);

	static function copySignature(signature:Null<SemanticSignatureInfo>):Null<SemanticSignatureInfo>
		return signature == null ? null : {
			label: signature.label,
			parameters: signature.parameters.copy(),
			result: signature.result
		};
}
