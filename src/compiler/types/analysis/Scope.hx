package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.core.Source.SourceSpan;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
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
	var scoped:Bool;
	var keyPathConstant:Null<String>;

	/** The index of the constructor without arguments a never-reassigned local holds, or null. */
	var knownConstructor:Null<Int>;
}

/** The locals a scope defines: by name, in definition order, and by binding id. */
private class ScopeDefinitions {
	public final values:Map<String, ScopeValue> = [];

	/**
	 * The same values in definition order, and by identity. Walking a map goes through an iterator object whose every call is dynamic, and
	 * looking a value up by id by walking the map compared every id of the scope; the visible set is asked for at every branch of every function.
	 */
	public final valueList:Array<ScopeValue> = [];

	public final valuesById:Map<String, ScopeValue> = [];

	public function new() {}
}

/** The locals a scope (a lambda's) captures, and how they are stored. */
private class ScopeCaptures {
	public final captures:Map<String, Bool> = [];
	public final storageTypes:Map<String, CompilerType> = [];
	public final cellCaptures:Map<String, Bool> = [];
	public final cellClasses:Map<String, String> = [];

	public function new() {}
}

/**
 * Lexical bindings, definite assignment, flow facts, and capture decisions.
 * Child scopes preserve stable binding IDs while maintaining branch-local facts.
 */
class Scope {
	final parent:Null<Scope>;
	final facts:FlowFacts;
	var nextLocalId:Int = 0;
	/*
		Most scopes define, assign, capture and track nothing, so each kind of record is made with its first entry (`own...`);
		until then the field is null.
	*/
	var definitions:Null<ScopeDefinitions> = null;

	/** Locals assigned in this scope, by binding id: its own and its parents'. */
	var assigned:Null<Map<String, Bool>> = null;

	var captured:Null<ScopeCaptures> = null;
	var mapKeySources:Null<Map<String, TypedExpression>> = null;

	function ownDefinitions():ScopeDefinitions {
		var current = definitions;
		if (current == null) {
			current = new ScopeDefinitions();
			definitions = current;
		}
		return current;
	}

	function ownAssigned():Map<String, Bool> {
		var current = assigned;
		if (current == null) {
			current = [];
			assigned = current;
		}
		return current;
	}

	function ownCaptured():ScopeCaptures {
		var current = captured;
		if (current == null) {
			current = new ScopeCaptures();
			captured = current;
		}
		return current;
	}

	public function new(?parent:Scope) {
		this.parent = parent;
		facts = new FlowFacts(parent == null ? null : parent.facts);
	}

	public function define(name:String, type:CompilerType, span:SourceSpan, initialized:Bool = true, ?bindingId:String,
			receiver:Bool = false,
			?localFunction:LocalFunction, ?declaration:String):Void {
		if (definitions != null && definitions.values.exists(name))
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		var value:ScopeValue = {
			source: name,
			declaration: declaration == null ? BindingWalker.key(name, span) : declaration,
			declared: type,
			id: bindingId == null ? '$' + 'l${allocateLocalId()}:$name' : bindingId,
			receiver: receiver,
			localFunction: localFunction,
			scoped: false,
			keyPathConstant: null,
			knownConstructor: null
		};
		var own = ownDefinitions();
		own.values.set(name, value);
		own.valueList.push(value);
		if (!own.valuesById.exists(value.id))
			own.valuesById.set(value.id, value);
		ownAssigned().set(value.id, initialized);
	}

	public function defineReceiver(type:CompilerType, span:SourceSpan):Void
		define("this", type, span, true, null, true);

	/** Only bindings proven never reassigned receive a declaration-sequence constant. */
	public function setKeyPathConstant(name:String, descriptor:String):Void {
		var value = resolveLocal(name);
		if (value != null) value.keyPathConstant = descriptor;
	}

	/** Records that `name`, never reassigned, holds the constructor without arguments at `index`. */
	public function setKnownConstructor(name:String, index:Int):Void {
		var value = resolveLocal(name);
		if (value != null) value.knownConstructor = index;
	}

	/** The constructor without arguments the local with binding `id` is known to hold, or -1. */
	public function knownConstructor(id:String):Int {
		var value = resolveById(id);
		return value == null || value.knownConstructor == null ? -1 : value.knownConstructor;
	}

	public function keyPathConstant(name:String):Null<String> {
		var value = resolveLocal(name);
		return value == null ? null : value.keyPathConstant;
	}

	public function isAssigned(name:String):Bool {
		var value = resolveLocal(name);
		return value != null && isAssignedId(value.id);
	}

	public function markAssigned(name:String):Void {
		var value = resolveLocal(name);
		if (value != null)
			ownAssigned().set(value.id, true);
	}

	/** For speculative typing: every visible local counts as assigned in this scope, not in its parents. */
	public function assumeAllAssigned():Void
		for (value in visibleValues())
			ownAssigned().set(value.id, true);

	public function setMapKeySource(name:String, source:Null<TypedExpression>):Void {
		var value = resolveLocal(name);
		if (value == null)
			return;
		if (source == null) {
			var sources = mapKeySources;
			if (sources != null)
				sources.remove(value.id);
		} else
			(mapKeySources == null ? mapKeySources = [] : mapKeySources).set(value.id, source);
	}

	public function mapKeySource(name:String):Null<TypedExpression> {
		var value = resolveLocal(name);
		if (value == null)
			return null;
		var sources = mapKeySources;
		if (sources != null && sources.exists(value.id))
			return sources.get(value.id);
		var outer = parent;
		return outer == null ? null : outer.mapKeySource(name);
	}

	/** What every continuing path assigned is assigned after them. With no continuing path the code after is unreachable, so every local counts as assigned. */
	public function mergeAssignmentsFrom(scopes:Array<Scope>):Void {
		if (scopes.length == 0) {
			assumeAllAssigned();
			return;
		}
		for (value in visibleValues()) {
			var allAssigned = true;
			for (scope in scopes)
				if (!scope.isAssignedId(value.id)) {
					allAssigned = false;
					break;
				}
			if (allAssigned)
				ownAssigned().set(value.id, true);
		}
	}

	/**
	 * Where control flow from `paths` rejoins this scope (after an if, a switch, a try, a conditional or a logical operator):
	 * a local is assigned when every path assigned it, and keeps a narrowing only where every path agrees on it, so what one
	 * branch assigned is no longer known to hold its earlier value. With no path, the code after is unreachable.
	 *
	 * Each path is this scope or a scope below it, and differs from this scope only in what the scopes between them recorded,
	 * so only the locals and expression facts those name are merged; a join whose branches recorded nothing changes nothing.
	 */
	public function join(paths:Array<Scope>):Void {
		if (paths.length == 0) {
			assumeAllAssigned();
			return;
		}
		var assignedIds:Null<Map<String, Bool>> = null,
			factKeys:Null<Map<String, Bool>> = null,
			forgotWholesale = false;
		for (path in paths) {
			var current:Null<Scope> = path;
			while (current != this) {
				if (current == null) {
					// Not below this scope: nothing bounds what it differs in, so merge everything visible.
					mergeAssignmentsFrom(paths);
					mergeRefinementsFrom(paths);
					return;
				}
				var ownAssignments = current.assigned;
				if (ownAssignments != null)
					for (id in ownAssignments.keys()) {
						if (assignedIds == null)
							assignedIds = [];
						assignedIds.set(id, true);
					}
				if (!current.facts.recordsNothing()) {
					if (factKeys == null)
						factKeys = [];
					if (current.facts.collectOwnKeys(factKeys))
						forgotWholesale = true;
				}
				current = current.parent;
			}
		}
		if (assignedIds != null)
			for (id in assignedIds.keys()) {
				if (isAssignedId(id) || resolveById(id) == null)
					continue;
				var allAssigned = true;
				for (path in paths)
					if (!path.isAssignedId(id)) {
						allAssigned = false;
						break;
					}
				if (allAssigned)
					ownAssigned().set(id, true);
			}
		if (factKeys == null)
			return;
		var expressionPrefix = '$' + 'expression:';
		if (forgotWholesale)
			for (key in facts.keys())
				if (StringTools.startsWith(key, expressionPrefix))
					factKeys.set(key, true);
		for (key in factKeys.keys()) {
			if (StringTools.startsWith(key, expressionPrefix)) {
				joinExpressionFact(key, paths);
				continue;
			}
			var value = resolveById(key);
			if (value == null)
				continue;
			var merged = paths[0].refinedType(value);
			for (index in 1...paths.length)
				if (!TypeRelations.equals(merged, paths[index].refinedType(value))) {
					merged = value.declared;
					break;
				}
			facts.refine(value.id, merged);
		}
	}

	/** An expression fact holds after a join when every path holds the same one; otherwise it is forgotten. */
	function joinExpressionFact(key:String, paths:Array<Scope>):Void {
		var merged = paths[0].facts.resolve(key),
			consistent = merged != null,
			stable = paths[0].facts.isStable(key);
		for (index in 1...paths.length) {
			var candidate = paths[index].facts.resolve(key);
			if (candidate == null || merged == null || !TypeRelations.equals(merged, candidate)) {
				consistent = false;
				break;
			}
			stable = stable && paths[index].facts.isStable(key);
		}
		if (consistent)
			facts.refine(key, merged, stable);
		else
			facts.invalidate(key);
	}

	function mergeRefinementsFrom(scopes:Array<Scope>):Void {
		if (scopes.length == 0)
			return;
		for (value in visibleValues()) {
			var merged = scopes[0].refinedType(value);
			for (index in 1...scopes.length)
				if (!TypeRelations.equals(merged, scopes[index].refinedType(value))) {
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
		for (key in expressionKeys.keys())
			joinExpressionFact(key, scopes);
	}

	public function defineCapture(name:String, type:CompilerType, span:SourceSpan, cell:Bool = false, ?cellClass:String,
			?bindingId:String,
			?storageType:CompilerType, ?localFunction:LocalFunction, ?declaration:String):Void {
		// A capture is the same variable as the one it captures, so it keeps that declaration's identity.
		define(name, type, span, true, bindingId, false, localFunction, declaration);
		var own = ownCaptured();
		own.captures.set(name, true);
		if (storageType != null)
			own.storageTypes.set(requireId(name), storageType);
		if (cell) {
			own.cellCaptures.set(name, true);
			if (cellClass != null)
				own.cellClasses.set(name, cellClass);
		}
	}

	public function recordAssignment(name:String, type:CompilerType):Void {
		var local = resolveLocal(name);
		if (local != null)
			facts.recordAssignment(local.id, type);
	}

	public function trackInvalidations():FlowFacts
		return facts.trackInvalidations();

	public function applyInvalidations(summary:FlowFacts):Void
		facts.applyInvalidations(summary);

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

	/** A possibly reassigned local also loses field and map-key facts derived from its old value. */
	public function invalidate(name:String):Void {
		var local = resolveLocal(name);
		if (local != null) {
			facts.invalidate(local.id);
			invalidateExpressionsForLocal(name);
		}
	}

	public function isCapture(name:String):Bool {
		var own = captured;
		return own != null && own.captures.exists(name) || (parent != null && parent.isCapture(name));
	}

	public function isCellCapture(name:String):Bool {
		var own = captured;
		return own != null && own.cellCaptures.exists(name) || (parent != null && parent.isCellCapture(name));
	}

	public function cellClass(name:String):Null<String> {
		var own = captured;
		return own != null && own.cellClasses.exists(name)
			? own.cellClasses.get(name) : (parent == null ? null : parent.cellClass(name));
	}

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
		var own = captured;
		if (own != null && own.storageTypes.exists(value.id))
			return own.storageTypes.get(value.id);
		return parent == null ? value.declared : parent.resolveDeclaredById(value.id, value.declared);
	}

	function resolveDeclaredById(id:String, fallback:CompilerType):CompilerType {
		var own = captured;
		return own != null && own.storageTypes.exists(id)
			? own.storageTypes.get(id) : (parent == null ? fallback : parent.resolveDeclaredById(id, fallback));
	}

	public function resolveId(name:String):Null<String> {
		var value = resolveLocal(name);
		return value == null ? null : value.id;
	}

	/** Mark and query the lexical binding, so a shadowing local does not inherit its lifetime. */
	public function markScoped(name:String):Void {
		var value = resolveLocal(name);
		if (value == null)
			throw 'Missing scoped binding "$name"';
		value.scoped = true;
	}

	public function isScoped(name:String):Bool {
		var value = resolveLocal(name);
		return value != null && value.scoped;
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
		var own = definitions;
		if (own != null && own.values.exists(name))
			return own.values.get(name);
		var outer = parent;
		return outer == null ? null : outer.resolveLocal(name);
	}

	function resolveById(id:String):Null<ScopeValue> {
		var own = definitions, found = own == null ? null : own.valuesById.get(id);
		if (found != null)
			return found;
		var outer = parent;
		return outer == null ? null : outer.resolveById(id);
	}

	function isAssignedId(id:String):Bool {
		var own = assigned;
		if (own != null && own.exists(id))
			return own.get(id);
		var outer = parent;
		return outer != null && outer.isAssignedId(id);
	}

	/** `value` as this scope sees it: its flow-refined type, or the declared one. */
	function refinedType(value:ScopeValue):CompilerType {
		var refined = facts.resolve(value.id);
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

	/** Primitive-key map locals visible here, respecting lexical shadowing. */
	public function visiblePrimitiveMapNames():Array<String> {
		var result = [];
		for (name in visibleDeclarations().keys())
			switch resolveDeclared(name) {
				case TMap(TString, _), TMap(TInt, _):
					result.push(name);
				default:
			}
		return result;
	}

	/** Every visible value, outermost scope first, in an array allocated at its final size. */
	public function visibleValues():Array<ScopeValue> {
		var count = 0, scope:Null<Scope> = this;
		while (scope != null) {
			var own = scope.definitions;
			if (own != null)
				count += own.valueList.length;
			scope = scope.parent;
		}
		var result:Array<ScopeValue> = [];
		result.resize(count);
		var end = count;
		scope = this;
		while (scope != null) {
			var own = scope.definitions;
			if (own != null) {
				var list = own.valueList;
				end -= list.length;
				for (index in 0...list.length)
					result[end + index] = list[index];
			}
			scope = scope.parent;
		}
		return result;
	}

	function allocateLocalId():Int {
		var outer = parent;
		return outer == null ? nextLocalId++ : outer.allocateLocalId();
	}
}
