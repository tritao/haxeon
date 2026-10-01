package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.TypedExpression;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstStatement;

/** Resolved local binding identity and its declared semantic type. */
/** A local declared as a function that is never reassigned, so a call through it runs exactly this body. */
typedef LocalFunction = {
	final arguments:Array<AstArgument>;
	final body:Array<AstStatement>;

	/** Locals visible where it was declared: assigning one of them changes no object, so it is no effect on flow facts. */
	final outerLocals:Array<String>;

	/** The scope it was declared in, where the free names of its body resolve. */
	final ?declaredIn:Scope;
}

private typedef ScopeValue = {
	final source:String;

	/** The declaration's identity, as `BindingWalker` names it; see `MapPrivacy`. */
	final declaration:String;

	final declared:CompilerType;
	final id:String;
	final receiver:Bool;
	final localFunction:Null<LocalFunction>;
}

/**
 * Lexical bindings, definite assignment, flow facts, and capture decisions.
 * Child scopes preserve stable binding IDs while maintaining branch-local facts.
 */
class Scope {
	final parent:Null<Scope>;
	final facts:FlowFacts;
	var nextLocalId:Int = 0;
	final values:Map<String, ScopeValue> = [];
	final assigned:Map<String, Bool> = [];
	final captures:Map<String, Bool> = [];
	final captureStorageTypes:Map<String, CompilerType> = [];
	final cellCaptures:Map<String, Bool> = [];
	final cellClasses:Map<String, String> = [];
	final mapKeySources:Map<String, TypedExpression> = [];

	public function new(?parent:Scope) {
		this.parent = parent;
		facts = new FlowFacts(parent == null ? null : parent.facts);
	}

	public function define(name:String, type:CompilerType, span:SourceSpan, initialized:Bool = true, ?bindingId:String, receiver:Bool = false,
			?localFunction:LocalFunction, ?declaration:String):Void {
		if (values.exists(name))
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		var value:ScopeValue = {
			source: name,
			declaration: declaration == null ? BindingWalker.key(name, span) : declaration,
			declared: type,
			id: bindingId == null ? '$' + 'l${allocateLocalId()}:$name' : bindingId,
			receiver: receiver,
			localFunction: localFunction
		};
		values.set(name, value);
		assigned.set(value.id, initialized);
	}

	public function defineReceiver(type:CompilerType, span:SourceSpan):Void
		define("this", type, span, true, null, true);

	public function isAssigned(name:String):Bool {
		var value = resolveLocal(name);
		return value != null && isAssignedId(value.id);
	}

	public function markAssigned(name:String):Void {
		var value = resolveLocal(name);
		if (value != null)
			assigned.set(value.id, true);
	}

	public function setMapKeySource(name:String, source:Null<TypedExpression>):Void {
		var value = resolveLocal(name);
		if (value == null)
			return;
		if (source == null)
			mapKeySources.remove(value.id);
		else
			mapKeySources.set(value.id, source);
	}

	public function mapKeySource(name:String):Null<TypedExpression> {
		var value = resolveLocal(name);
		if (value == null)
			return null;
		if (mapKeySources.exists(value.id))
			return mapKeySources.get(value.id);
		var outer = parent;
		return outer == null ? null : outer.mapKeySource(name);
	}

	public function mergeAssignmentsFrom(scopes:Array<Scope>):Void {
		if (scopes.length == 0)
			return;
		for (value in visibleValues()) {
			var allAssigned = true;
			for (scope in scopes)
				if (!scope.isAssignedId(value.id)) {
					allAssigned = false;
					break;
				}
			if (allAssigned)
				assigned.set(value.id, true);
		}
	}

	public function mergeRefinementsFrom(scopes:Array<Scope>):Void {
		if (scopes.length == 0)
			return;
		for (value in visibleValues()) {
			var merged = scopes[0].resolvedTypeById(value.id);
			for (index in 1...scopes.length)
				if (!TypeRelations.equals(merged, scopes[index].resolvedTypeById(value.id))) {
					merged = value.declared;
					break;
				}
			facts.refine(value.id, merged);
		}
		var expressionKeys:Map<String, Bool> = [],
			expressionPrefix = '$' + 'expression:';
		for (scope in scopes)
			for (key in scope.facts.keys())
				if (StringTools.startsWith(key, expressionPrefix))
					expressionKeys.set(key, true);
		for (key in expressionKeys.keys()) {
			var merged = scopes[0].facts.resolve(key),
				consistent = merged != null;
			for (index in 1...scopes.length) {
				var candidate = scopes[index].facts.resolve(key);
				if (candidate == null || merged == null || !TypeRelations.equals(merged, candidate)) {
					consistent = false;
					break;
				}
			}
			if (consistent)
				facts.refine(key, merged);
			else
				facts.invalidate(key);
		}
	}

	public function defineCapture(name:String, type:CompilerType, span:SourceSpan, cell:Bool = false, ?cellClass:String, ?bindingId:String,
			?storageType:CompilerType, ?localFunction:LocalFunction, ?declaration:String):Void {
		// A capture is the same variable as the one it captures, so it keeps that declaration's identity.
		define(name, type, span, true, bindingId, false, localFunction, declaration);
		captures.set(name, true);
		if (storageType != null)
			captureStorageTypes.set(requireId(name), storageType);
		if (cell) {
			cellCaptures.set(name, true);
			if (cellClass != null)
				cellClasses.set(name, cellClass);
		}
	}

	public function refine(name:String, type:CompilerType):Void {
		var local = resolveLocal(name);
		if (local == null)
			local = resolveById(name);
		if (local != null)
			facts.refine(local.id, type);
	}

	/** Which local maps only this function can reach; see MapEscapeAnalysis. Set on the function's outermost scope. */
	var privacy:Null<MapPrivacy> = null;

	public function setMapPrivacy(value:MapPrivacy):Void
		privacy = value;

	function mapPrivacy():Null<MapPrivacy> {
		var scope:Null<Scope> = this;
		while (scope != null) {
			var found = scope.privacy;
			if (found != null)
				return found;
			scope = scope.parent;
		}
		return null;
	}

	/**
	 * The typer met a use of `name` at `span`. Returns false when it resolves to a private map but the analysis that
	 * made it private did not see this use as a map operand: the two scopings then disagree, and treating the map as
	 * private could be wrong.
	 */
	public function privateMapUseIsKnown(name:String, span:SourceSpan):Bool {
		var value = resolveLocal(name), found = mapPrivacy();
		if (value == null || found == null || !found.isPrivate(value.declaration))
			return true;
		return found.isOperandUse(name, span);
	}

	/** Whether the local with binding `id` is a map that calls cannot reach. */
	public function isPrivateMap(id:String):Bool {
		var value = resolveById(id), found = mapPrivacy();
		return value != null && found != null && found.isPrivate(value.declaration);
	}

	/** Source names of the visible locals that are maps only this function can reach. */
	public function visiblePrivateMapNames():Array<String>
		return [for (value in visibleValues()) if (isPrivateMap(value.id)) value.source];

	public function refineExpression(path:String, type:CompilerType, stable:Bool = false):Void
		facts.refine('$' + 'expression:$path', type, stable);

	public function resolveExpression(path:String):Null<CompilerType>
		return facts.resolve('$' + 'expression:$path');

	public function invalidateExpression(path:String):Void
		facts.invalidatePrefix('$' + 'expression:$path');

	public function invalidateExpressionValue(path:String):Void
		facts.invalidate('$' + 'expression:$path');

	public function invalidateExpressionNamespace(path:String):Void
		facts.invalidateNamespace('$' + 'expression:$path');

	/** Unlike the namespace form, also forgets facts that calls cannot change. */
	public function invalidateExpressionNamespaceCompletely(path:String):Void
		facts.invalidateNamespaceCompletely('$' + 'expression:$path');

	/** Calls may mutate any reachable object, but cannot directly reassign uncaptured locals. */
	public function invalidateAllExpressions():Void
		facts.invalidateAllExpressions();

	/** A store to some object's `field` may falsify any fact read through a field of that name. */
	public function invalidateField(field:String):Void
		facts.invalidateField(field);

	public function invalidateExpressionsForLocal(name:String):Void {
		var local = resolveLocal(name);
		if (local != null) {
			facts.invalidatePrefix('$' + 'expression:' + local.id);
			// Map entries keyed by this local are filed under the map, so they only mention it.
			facts.invalidateMentioning(':' + local.id);
		}
	}

	public function invalidate(name:String):Void {
		var local = resolveLocal(name);
		if (local != null)
			facts.invalidate(local.id);
	}

	public function isCapture(name:String):Bool
		return captures.exists(name) || (parent != null && parent.isCapture(name));

	public function isCellCapture(name:String):Bool
		return cellCaptures.exists(name) || (parent != null && parent.isCellCapture(name));

	public function cellClass(name:String):Null<String>
		return cellClasses.exists(name) ? cellClasses.get(name) : (parent == null ? null : parent.cellClass(name));

	public function requireCellClass(name:String):String {
		var resolved = cellClass(name);
		if (resolved == null)
			throw 'Missing capture cell for "$name"';
		return resolved;
	}

	public function resolve(name:String):Null<CompilerType> {
		var value = resolveLocal(name);
		if (value == null)
			return null;
		var refined = facts.resolve(value.id);
		return refined == null ? value.declared : refined;
	}

	public function resolveDeclared(name:String):Null<CompilerType> {
		var value = resolveLocal(name);
		if (value == null)
			return null;
		if (captureStorageTypes.exists(value.id))
			return captureStorageTypes.get(value.id);
		return parent == null ? value.declared : parent.resolveDeclaredById(value.id, value.declared);
	}

	function resolveDeclaredById(id:String, fallback:CompilerType):CompilerType
		return captureStorageTypes.exists(id) ? captureStorageTypes.get(id) : (parent == null ? fallback : parent.resolveDeclaredById(id, fallback));

	public function resolveId(name:String):Null<String> {
		var value = resolveLocal(name);
		return value == null ? null : value.id;
	}

	public function localFunction(name:String):Null<LocalFunction> {
		var value = resolveLocal(name);
		return value == null ? null : value.localFunction;
	}

	public function localFunctionParameters(name:String):Null<Array<AstArgument>> {
		var found = localFunction(name);
		return found == null ? null : found.arguments;
	}

	public function requireId(name:String):String {
		var value = resolveLocal(name);
		if (value == null)
			throw 'Missing binding for local "$name"';
		return value.id;
	}

	public function isReceiver(name:String):Bool {
		var value = resolveLocal(name);
		return value != null && value.receiver;
	}

	function resolveLocal(name:String):Null<ScopeValue> {
		if (values.exists(name))
			return values.get(name);
		var outer = parent;
		return outer == null ? null : outer.resolveLocal(name);
	}

	function resolveById(id:String):Null<ScopeValue> {
		for (_ => value in values)
			if (value.id == id)
				return value;
		var outer = parent;
		return outer == null ? null : outer.resolveById(id);
	}

	function isAssignedId(id:String):Bool {
		if (assigned.exists(id))
			return assigned.get(id);
		var outer = parent;
		return outer != null && outer.isAssignedId(id);
	}

	function resolvedTypeById(id:String):CompilerType {
		var value = resolveById(id);
		if (value == null)
			throw 'Missing binding "$id" while merging flow facts';
		var refined = facts.resolve(id);
		return refined == null ? value.declared : refined;
	}

	/** The declaration the local `name` refers to here, in `BindingWalker.key` form. */
	public function declarationOf(name:String):Null<String> {
		var value = resolveLocal(name);
		return value == null ? null : value.declaration;
	}

	/** Every visible local's name with its declaration; where a name is declared more than once, the innermost wins. */
	public function visibleDeclarations():Map<String, String> {
		var result:Map<String, String> = [];
		for (value in visibleValues())
			result.set(value.source, value.declaration);
		return result;
	}

	/** Source names of every local visible here, including `this`. */
	public function visibleLocalNames():Array<String>
		return [for (value in visibleValues()) value.source];

	/** Declared array locals visible here, respecting lexical shadowing. */
	public function visibleArrayNames():Array<String> {
		var result = [];
		for (name in visibleDeclarations().keys())
			switch resolveDeclared(name) {
				case TArray(_):
					result.push(name);
				default:
			}
		return result;
	}

	function visibleValues():Array<ScopeValue> {
		var outer = parent,
			result:Array<ScopeValue> = outer == null ? [] : outer.visibleValues();
		for (_ => value in values)
			result.push(value);
		return result;
	}

	function allocateLocalId():Int {
		var outer = parent;
		return outer == null ? nextLocalId++ : outer.allocateLocalId();
	}
}
