package compiler.semantic;

/**
 * The names that resolve to declarations at one point in a module: its explicit imports, the program's types, its own
 * declarations, and (in a nested table) a class's or function's type parameters.
 *
 * A module's table used to be a map filled with every type of the program (some 3,000 entries), and each class and
 * generic function copied it again: millions of insertions per compile. Here the program-wide and package-wide maps are
 * attached as read-only layers that are shared, and only the entries a module sets itself are stored in it.
 *
 * Lookup order is the entries set here, then the attached layers in the order they were attached, then the enclosing
 * table. That is the order the maps were filled in before: a layer was added only for names nothing earlier had, so
 * `attach` must be called at the point where the names would have been copied in.
 */
class AliasTable {
	final parent:Null<AliasTable>;
	final layers:Array<Map<String, String>> = [];
	final local:Map<String, String> = [];
	var removed:Null<Map<String, Bool>> = null;

	/** A table with no names that resolves through `parent`, if any, and that `set` and `remove` change without touching it. */
	public function new(?parent:AliasTable) {
		this.parent = parent;
	}

	/** A table that starts from `entries` and leaves that map unchanged; names set later are kept apart from it. */
	public static function of(entries:Map<String, String>):AliasTable {
		var table = new AliasTable();
		table.attach(entries);
		return table;
	}

	/** Adds a shared, read-only map after the layers attached so far. */
	public function attach(layer:Map<String, String>):Void
		layers.push(layer);

	public function get(name:String):Null<String> {
		var value = local.get(name);
		if (value != null)
			return value;
		if (removed != null && removed.exists(name))
			return null;
		for (layer in layers) {
			value = layer.get(name);
			if (value != null)
				return value;
		}
		return parent == null ? null : parent.get(name);
	}

	public function exists(name:String):Bool
		return get(name) != null;

	public function set(name:String, target:String):Void {
		local.set(name, target);
		if (removed != null)
			removed.remove(name);
	}

	/** Hides `name` from this table, however it would otherwise resolve. */
	public function remove(name:String):Void {
		local.remove(name);
		if (!exists(name))
			return;
		if (removed == null)
			removed = [];
		removed.set(name, true);
	}

	/** A table for a nested scope: it sees everything this one does and changes only itself. */
	public function child():AliasTable
		return new AliasTable(this);
}
