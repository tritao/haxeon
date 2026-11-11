package compiler.semantic;

/**
 * The names in scope while a body is canonicalized: each maps to true (a module-level name that qualifies) or false (a local that
 * shadows it). A nested scope is a node over its parent, so binding the names of a block or a parameter list costs only those names;
 * it used to copy the whole enclosing scope (the module's every name) for each one.
 */
private class LocalScopeNode {
	public final parent:Null<LocalScopeNode>;
	public final own:Map<String, Bool>;

	public function new(own:Map<String, Bool>, parent:Null<LocalScopeNode>) {
		this.own = own;
		this.parent = parent;
	}
}

abstract LocalScope(LocalScopeNode) {
	inline function new(node:LocalScopeNode)
		this = node;

	/** A scope that is `names` and nothing else: the module's table, shared, not copied. */
	public static function ofNames(names:Map<String, Bool>):LocalScope
		return new LocalScope(new LocalScopeNode(names, null));

	/** This scope with `names` bound as locals (each maps to false). The scope itself is unchanged. */
	public function bind(names:Array<Null<String>>):LocalScope {
		var own:Map<String, Bool> = [];
		for (name in names)
			if (name != null)
				own.set(name, false);
		return new LocalScope(new LocalScopeNode(own, this));
	}

	public function exists(name:String):Bool {
		var node = this;
		while (node != null) {
			if (node.own.exists(name))
				return true;
			node = node.parent;
		}
		return false;
	}

	/** The innermost entry for `name`: false for a local, true for a qualifying module name, null when absent. */
	public function get(name:String):Null<Bool> {
		var node = this;
		while (node != null) {
			var value = node.own.get(name);
			if (value != null)
				return value;
			node = node.parent;
		}
		return null;
	}

	/** Sets `name` in this scope's own table; callers only set on a scope they created with `bind`. */
	public inline function set(name:String, value:Bool):Void
		this.own.set(name, value);
}
