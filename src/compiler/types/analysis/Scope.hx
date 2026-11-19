package compiler.types.analysis;

import compiler.core.InternalError;
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

/** A local as the typer knows it: its name, declaration, binding id and the facts recorded about it. */
typedef LocalBinding = {
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

/**
 * The locals a scope defines, in definition order, found by name or binding id. Most scopes define a few, which a scan finds
 * sooner than a hash; a scope with more gets maps.
 */
private class ScopeDefinitions {
	static inline final SCAN_LIMIT = 8;

	public final valueList:Array<LocalBinding> = [];

	var byName:Null<Map<String, LocalBinding>> = null;

	/** The first value defined with each binding id. */
	var byId:Null<Map<String, LocalBinding>> = null;

	public function new() {}

	public function named(name:String):Null<LocalBinding> {
		var map = byName;
		if (map != null)
			return map.get(name);
		for (value in valueList)
			if (value.source == name)
				return value;
		return null;
	}

	public function withId(id:String):Null<LocalBinding> {
		var map = byId;
		if (map != null)
			return map.get(id);
		for (value in valueList)
			if (value.id == id)
				return value;
		return null;
	}

	/** Adds `value`, whose name this scope does not define yet. */
	public function add(value:LocalBinding):Void {
		valueList.push(value);
		var names = byName, ids = byId;
		if (names != null && ids != null) {
			names.set(value.source, value);
			if (!ids.exists(value.id))
				ids.set(value.id, value);
		} else if (valueList.length > SCAN_LIMIT) {
			names = [];
			ids = [];
			for (each in valueList) {
				names.set(each.source, each);
				if (!ids.exists(each.id))
					ids.set(each.id, each);
			}
			byName = names;
			byId = ids;
		}
	}
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

	/** The outermost scope of the function or lambda, which holds its bindings by declaration (`bindingOf`). */
	final root:Scope;

	/** On the root: every binding defined in the function or lambda, by declaration key; the last definition wins. */
	var byDeclaration:Null<Map<String, LocalBinding>> = null;
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
		root = parent == null ? this : parent.root;
		facts = new FlowFacts(parent == null ? null : parent.facts);
	}

	/** The binding of the declaration with key `declaration` (`BindingWalker.key`), or null when none was defined. */
	public function bindingOf(declaration:String):Null<LocalBinding> {
		var table = root.byDeclaration;
		return table == null ? null : table.get(declaration);
	}

	public function define(name:String, type:CompilerType, span:SourceSpan, initialized:Bool = true, ?bindingId:String,
			receiver:Bool = false,
			?localFunction:LocalFunction, ?declaration:String):LocalBinding {
		if (definitions != null && definitions.named(name) != null)
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		var value:LocalBinding = {
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
		ownDefinitions().add(value);
		ownAssigned().set(value.id, initialized);
		var table = root.byDeclaration;
		if (table == null)
			table = root.byDeclaration = [];
		table.set(value.declaration, value);
		return value;
	}

	public function defineReceiver(type:CompilerType, span:SourceSpan):LocalBinding
		return define("this", type, span, true, null, true);

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

	/**
	 * Where control flow from `paths` rejoins this scope (after an if, a switch, a try, a do-while body, a conditional or a
	 * logical operator):
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
				if (current == null)
					throw new InternalError('Scope.join: a path is not this scope or below it');
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

	public function defineCapture(name:String, type:CompilerType, span:SourceSpan, cell:Bool = false, ?cellClass:String,
			?bindingId:String,
			?storageType:CompilerType, ?localFunction:LocalFunction, ?declaration:String):LocalBinding {
		// A capture is the same variable as the one it captures, so it keeps that declaration's identity.
		var value = define(name, type, span, true, bindingId, false, localFunction, declaration);
		var own = ownCaptured();
		own.captures.set(value.id, true);
		if (storageType != null)
			own.storageTypes.set(value.id, storageType);
		if (cell) {
			own.cellCaptures.set(value.id, true);
			if (cellClass != null)
				own.cellClasses.set(value.id, cellClass);
		}
		return value;
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
		var value = resolveLocal(name);
		return value != null && isCaptured(value);
	}

	public function isCellCapture(name:String):Bool {
		var value = resolveLocal(name);
		return value != null && isCellCaptured(value);
	}

	public function cellClass(name:String):Null<String> {
		var value = resolveLocal(name);
		return value == null ? null : cellClassOf(value);
	}

	/** Whether `value` is a capture of the lambda this scope is in. */
	public function isCaptured(value:LocalBinding):Bool {
		var scope:Null<Scope> = this;
		while (scope != null) {
			var own = scope.captured;
			if (own != null && own.captures.exists(value.id))
				return true;
			scope = scope.parent;
		}
		return false;
	}

	public function isCellCaptured(value:LocalBinding):Bool {
		var scope:Null<Scope> = this;
		while (scope != null) {
			var own = scope.captured;
			if (own != null && own.cellCaptures.exists(value.id))
				return true;
			scope = scope.parent;
		}
		return false;
	}

	public function cellClassOf(value:LocalBinding):Null<String> {
		var scope:Null<Scope> = this;
		while (scope != null) {
			var own = scope.captured;
			if (own != null && own.cellClasses.exists(value.id))
				return own.cellClasses.get(value.id);
			scope = scope.parent;
		}
		return null;
	}

	public function requireCellClass(name:String):String {
		var resolved = cellClass(name);
		if (resolved == null)
			throw new InternalError('Missing capture cell for "$name"');
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
			throw new InternalError('Missing scoped binding "$name"');
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
			throw new InternalError('Missing binding for local "$name"');
		return value.id;
	}

	public function isReceiver(name:String):Bool {
		var value = resolveLocal(name);
		return value != null && value.receiver;
	}

	function resolveLocal(name:String):Null<LocalBinding> {
		var scope:Null<Scope> = this;
		while (scope != null) {
			var own = scope.definitions;
			if (own != null) {
				var found = own.named(name);
				if (found != null)
					return found;
			}
			scope = scope.parent;
		}
		return null;
	}

	function resolveById(id:String):Null<LocalBinding> {
		var own = definitions, found = own == null ? null : own.withId(id);
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
	function refinedType(value:LocalBinding):CompilerType {
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
	public function visibleValues():Array<LocalBinding> {
		var count = 0, scope:Null<Scope> = this;
		while (scope != null) {
			var own = scope.definitions;
			if (own != null)
				count += own.valueList.length;
			scope = scope.parent;
		}
		var result:Array<LocalBinding> = [];
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
