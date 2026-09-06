package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;

/** Resolved local binding identity and its declared semantic type. */
private typedef ScopeValue = {
	final source:String;
	final declared:CompilerType;
	final id:String;
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

	public function define(name:String, type:CompilerType, span:SourceSpan, initialized:Bool = true):Void {
		if (values.exists(name))
			throw new CompileError(new Diagnostic("E1001", 'Duplicate local "$name"', span));
		var value:ScopeValue = {
			source: name,
			declared: type,
			id: '$' + 'l${allocateLocalId()}:$name'
		};
		values.set(name, value);
		assigned.set(value.id, initialized);
	}

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

	public function defineCapture(name:String, type:CompilerType, span:SourceSpan, cell:Bool = false, ?cellClass:String):Void {
		define(name, type, span);
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

	public function invalidate(name:String):Void {
		var local = resolveLocal(name);
		if (local != null)
			facts.invalidate(local.id);
	}

	public function isCapture(name:String):Bool
		return captures.exists(name);

	public function isCellCapture(name:String):Bool
		return cellCaptures.exists(name);

	public function cellClass(name:String):Null<String>
		return cellClasses.get(name);

	public function requireCellClass(name:String):String {
		if (!cellClasses.exists(name))
			throw 'Missing capture cell for "$name"';
		return cellClasses.get(name);
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
