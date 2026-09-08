package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.types.TypeRelations;

/** Resolved local binding identity and its declared semantic type. */
private typedef ScopeValue = {
	final source:String;
	final declared:CompilerType;
	final id:String;
	final receiver:Bool;
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
	final cellCaptures:Map<String, Bool> = [];
	final cellClasses:Map<String, String> = [];

	public function new(?parent:Scope) {
		this.parent = parent;
		facts = new FlowFacts(parent == null ? null : parent.facts);
	}

	public function define(name:String, type:CompilerType, span:SourceSpan, initialized:Bool = true, ?bindingId:String, receiver:Bool = false):Void {
		if (values.exists(name))
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		var value:ScopeValue = {
			source: name,
			declared: type,
			id: bindingId == null ? '$' + 'l${allocateLocalId()}:$name' : bindingId,
			receiver: receiver
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
	}

	public function defineCapture(name:String, type:CompilerType, span:SourceSpan, cell:Bool = false, ?cellClass:String, ?bindingId:String):Void {
		define(name, type, span, true, bindingId);
		captures.set(name, true);
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

	public function refineExpression(path:String, type:CompilerType):Void
		facts.refine('$' + 'expression:$path', type);

	public function resolveExpression(path:String):Null<CompilerType>
		return facts.resolve('$' + 'expression:$path');

	public function invalidateExpression(path:String):Void
		facts.invalidatePrefix('$' + 'expression:$path');

	public function invalidateExpressionValue(path:String):Void
		facts.invalidate('$' + 'expression:$path');

	public function invalidateExpressionNamespace(path:String):Void
		facts.invalidateNamespace('$' + 'expression:$path');

	/** Calls may mutate any reachable object, but cannot directly reassign uncaptured locals. */
	public function invalidateAllExpressions():Void
		facts.invalidateAllExpressions();

	public function invalidateExpressionsForLocal(name:String):Void {
		var local = resolveLocal(name);
		if (local != null)
			facts.invalidatePrefix('$' + 'expression:' + local.id);
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
		return value == null ? null : value.declared;
	}

	public function resolveId(name:String):Null<String> {
		var value = resolveLocal(name);
		return value == null ? null : value.id;
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
