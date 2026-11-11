package compiler.ir;

import compiler.ir.Ir.IrObject;

/**
 * Which function a method call reaches, answered once per program for every pass that asks.
 *
 * The passes that resolve a call on a class receiver (the optional-scalar flow, the scalar call ABI, the inliner) each used to walk
 * the base chain and the subclasses through string maps on every call, one of them without remembering the answer. This holds the
 * answers: each class's methods with its bases resolved, its direct subclasses, and for a (class, method) pair whether every class
 * that extends it runs the same function. A table is valid for one list of objects; `of` hands back the cached table while the
 * objects are the same instances in the same order, and builds a new one when a pass has replaced or added a class.
 */
class IrMethodResolution {
	static var cached:Null<IrMethodResolution>;

	final source:Array<IrObject>;
	final objects:Map<String, IrObject> = [];
	final children:Map<String, Array<String>> = [];
	final tables:Map<String, Map<String, String>> = [];
	final uniform:Map<String, Map<String, String>> = [];
	final subtree:Map<String, Array<String>> = [];

	/** Marks an answer of "no single function" in a memo, since a map cannot hold null for a missing key apart from absence. */
	static inline final NONE = "";

	public static function of(declarations:Array<IrObject>):IrMethodResolution {
		var table = cached;
		if (table == null || !table.sameObjects(declarations)) {
			table = new IrMethodResolution(declarations);
			cached = table;
		}
		return table;
	}

	function new(declarations:Array<IrObject>) {
		source = declarations.copy();
		for (object in declarations) {
			objects.set(object.name, object);
			if (object.base != null) {
				var base = Std.string(object.base), list = children.get(base);
				if (list == null) {
					list = [];
					children.set(base, list);
				}
				list.push(object.name);
			}
		}
	}

	function sameObjects(declarations:Array<IrObject>):Bool {
		if (declarations.length != source.length)
			return false;
		for (index in 0...source.length)
			if (source[index] != declarations[index])
				return false;
		return true;
	}

	/** The function `typeName` runs for `method`, looking through its bases; null when there is none or the class is unknown. */
	public function find(typeName:String, method:String):Null<String> {
		var table = methodsOf(typeName, 0);
		if (table == null)
			return null;
		var found = table.get(method);
		return found == null ? null : found;
	}

	/**
	 * The function every class that is `typeName` or extends it runs for `method`, or null when they differ or one has none.
	 * Answered for a class by its direct subclasses' answers, so each pair is worked out once.
	 */
	public function uniqueImplementation(typeName:String, method:String):Null<String> {
		var memo = uniform.get(typeName);
		if (memo == null) {
			memo = [];
			uniform.set(typeName, memo);
		}
		var known = memo.get(method);
		if (known != null)
			return known == NONE ? null : known;
		var target = find(typeName, method);
		if (target != null) {
			var direct = children.get(typeName);
			if (direct != null)
				for (child in direct)
					if (uniqueImplementation(child, method) != target) {
						target = null;
						break;
					}
		}
		memo.set(method, target == null ? NONE : target);
		return target;
	}

	/** `typeName` and every class that extends it, so a caller that records what it looked at can record them all. */
	public function subtreeOf(typeName:String):Array<String> {
		var result = subtree.get(typeName);
		if (result == null) {
			result = [];
			var pending = [typeName], visited:Map<String, Bool> = [];
			while (pending.length > 0) {
				var name = pending.pop();
				if (visited.exists(name))
					continue;
				visited.set(name, true);
				result.push(name);
				var direct = children.get(name);
				if (direct != null)
					for (child in direct)
						pending.push(child);
			}
			subtree.set(typeName, result);
		}
		return result;
	}

	function methodsOf(typeName:String, depth:Int):Null<Map<String, String>> {
		var table = tables.get(typeName);
		if (table != null)
			return table;
		var object = objects.get(typeName);
		if (object == null || depth > 256)
			return null;
		table = [];
		if (object.base != null) {
			var inherited = methodsOf(Std.string(object.base), depth + 1);
			if (inherited != null)
				for (name => target in inherited)
					table.set(name, target);
		}
		// The first entry of a name wins, as the walks this replaces took the first match in a class's list.
		var own:Map<String, Bool> = [];
		for (entry in object.methods)
			if (!own.exists(entry.name)) {
				own.set(entry.name, true);
				table.set(entry.name, entry.functionName);
			}
		tables.set(typeName, table);
		return table;
	}
}
