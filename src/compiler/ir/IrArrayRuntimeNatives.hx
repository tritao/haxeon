package compiler.ir;

/** Exact runtime storage names shared by enum escape classification. Unknown names fail closed.
 * Replace this registry with declared native roles when array natives acquire them (a1 debt).
 */
class IrArrayRuntimeNatives {
	static final names:Map<String, Bool> = build();

	static function build():Map<String, Bool> {
		var result:Map<String, Bool> = [
			"__array_alloc_typed_ref" => true,
			"__array_check_cast" => true,
			"__array_get_any" => true,
			"__array_set_any" => true,
			"__array_remove_at_any" => true,
			"__array_join_bytes" => true
		];
		for (kind in ["i32", "i64", "f64", "bytes", "bool", "ref"])
			result.set("__array_alloc_" + kind, true);
		for (kind in ["i32", "i64", "f64", "bytes", "bool", "ref", "any"])
			for (operation in [
				"alloc",
				"copy",
				"concat",
				"slice",
				"splice",
				"index_of",
				"push",
				"unshift",
				"insert",
				"pop",
				"shift",
				"resize",
				"remove",
				"reverse"
			])
				result.set("__array_" + operation + "_" + kind, true);
		return result;
	}

	public static function isStorage(name:String):Bool
		return names.exists(name);
}
