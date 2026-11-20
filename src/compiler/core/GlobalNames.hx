package compiler.core;

/**
 * Names that outlive the work that made them (a function's qualified name, a generated specialization's), interned once for
 * the process, in the collector's pages rather than in the arena of the work that spelled them first (docs/design/ARENAS.md,
 * "Data rules for arenas"). Outside any arena a name is returned as it is.
 */
class GlobalNames {
	@:processWide("names are interned for the process by design: the global arena")
	static final names:Map<String, String> = [];

	public static function of(name:String):String {
		if (Arena.depth == 0)
			return name;
		var known = names.get(name);
		if (known != null)
			return known;
		var global = Arena.toGlobal(name);
		names.set(global, global);
		return global;
	}
}
