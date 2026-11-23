package compiler.semantic;

import compiler.core.Source.SourceSpan;

/**
 * A module's variable or function named through the module's name (`Settings.hits` with `import pack.Settings`, where module
 * pack.Settings has no type of that name or its type has no such static): a Haxeon extension that Haxe rejects, which the lint rule
 * `module-namespace` reports. Haxe's forms are an import of the member (`import pack.Settings.hits`) or its full path.
 */
typedef ModuleNamespaceUse = {
	/** The path as written, from the module's name: `Settings.hits`. */
	final written:String;

	/** The member it names: `pack.Settings.hits`. */
	final member:String;

	final span:SourceSpan;
}

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

	/** Where each module-level variable is stored (ModuleFields): `pack.Mod.x` => `pack.Mod$fields.x`; shared, read-only. */
	var moduleFieldStorage:Null<Map<String, String>> = null;
	var typeStatics:Null<Map<String, Bool>> = null;
	var moduleMembers:Null<Map<String, Bool>> = null;
	var namespaceUses:Null<Array<ModuleNamespaceUse>> = null;

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

	/** Whether this table sets `name` itself (a module's own declaration, an import's marker), not through a layer or parent. */
	public function setsOwn(name:String):Bool
		return local.exists(name);

	/** Hides `name` from this table, however it would otherwise resolve. */
	public function remove(name:String):Void {
		local.remove(name);
		if (!exists(name))
			return;
		if (removed == null)
			removed = [];
		removed.set(name, true);
	}

	/**
	 * Resolves module-level variables, by their names as module members, to the hidden class that stores them. `statics`
	 * names those that share their name with a static of the module's own class (`pack.Store.count`), and `members` every
	 * module-level variable and function by its path as a module member (`pack.Settings.hits`, `pack.Settings.record`).
	 */
	public function useModuleFieldStorage(storage:Map<String, String>, statics:Map<String, Bool>,
			members:Map<String, Bool>):Void {
		moduleFieldStorage = storage;
		typeStatics = statics;
		moduleMembers = members;
	}

	/** Whether `path` (`pack.Store.count`) is a static of the module's own class as well as a module-level variable. */
	public function isTypeStatic(path:String):Bool {
		var statics = nearest(table -> table.typeStatics);
		return statics != null && statics.exists(path);
	}

	/** Whether `path` (`pack.Settings.hits`) is a module-level variable or function, by its path as a module member. */
	public function isModuleMember(path:String):Bool {
		var members = nearest(table -> table.moduleMembers);
		return members != null && members.exists(path);
	}

	/** Collects the module-namespace uses that canonicalizing through this table and the tables nested in it finds into `uses`. */
	public function recordNamespaceUses(uses:Array<ModuleNamespaceUse>):Void
		namespaceUses = uses;

	/** Records `use` where `recordNamespaceUses` asked, if anything did. */
	public function noteNamespaceUse(use:ModuleNamespaceUse):Void {
		var uses = nearest(table -> table.namespaceUses);
		if (uses != null)
			uses.push(use);
	}

	/** What `read` gives for this table or, when that is null, the nearest enclosing table it is not null for. */
	function nearest<T>(read:AliasTable->Null<T>):Null<T> {
		var table:Null<AliasTable> = this;
		while (table != null) {
			var value = read(table);
			if (value != null)
				return value;
			table = table.parent;
		}
		return null;
	}

	/**
	 * `path` with a module-level variable it starts with (`pack.Mod.x`, `pack.Mod.x.push`) named where it is stored
	 * (`pack.Mod$fields.x`, `pack.Mod$fields.x.push`); `path` itself otherwise.
	 */
	public function moduleFieldPath(path:String):String {
		var storage = moduleFieldStorage, table = parent;
		while (storage == null && table != null) {
			storage = table.moduleFieldStorage;
			table = table.parent;
		}
		if (storage == null)
			return path;
		var end = path.indexOf(".");
		while (end >= 0) {
			end = path.indexOf(".", end + 1);
			var prefix = end < 0 ? path : path.substr(0, end), stored = storage.get(prefix);
			if (stored != null)
				return end < 0 ? stored : stored + path.substr(end);
		}
		return path;
	}

	/** A table for a nested scope: it sees everything this one does and changes only itself. */
	public function child():AliasTable
		return new AliasTable(this);
}
