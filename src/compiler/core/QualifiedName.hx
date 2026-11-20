package compiler.core;

/** Operations on canonical dot-separated compiler names. */
class QualifiedName {
	public static function parent(path:String):Null<String> {
		var separator = path.lastIndexOf(".");
		return separator < 0 ? null : path.substring(0, separator);
	}

	public static function parentOrEmpty(path:String):String {
		var value = parent(path);
		return value == null ? "" : value;
	}

	public static function first(path:String):String {
		var separator = path.indexOf(".");
		return separator < 0 ? path : path.substring(0, separator);
	}

	public static function last(path:String):String {
		var separator = path.lastIndexOf(".");
		return separator < 0 ? path : path.substring(separator + 1, path.length);
	}

	public static function split(path:String):Array<String> {
		var parts:Array<String> = [], start = 0;
		for (cursor in 0...path.length)
			if (path.charCodeAt(cursor) == 46) {
				parts.push(path.substring(start, cursor));
				start = cursor + 1;
			}
		parts.push(path.substring(start, path.length));
		return parts;
	}

	/**
	 * `table` by owner, then by the last component of its names: for a `name` without a dot, `table.get(owner + "." + name)` is
	 * `byOwner(table).get(owner).get(name)`, found without building the qualified name.
	 */
	public static function byOwner<V>(table:Map<String, V>):Map<String, Map<String, V>> {
		var result:Map<String, Map<String, V>> = [];
		for (key => value in table) {
			var separator = key.lastIndexOf(".");
			if (separator < 0)
				continue;
			var owner = key.substring(0, separator), members = result.get(owner);
			if (members == null) {
				members = [];
				result.set(owner, members);
			}
			members.set(key.substring(separator + 1, key.length), value);
		}
		return result;
	}
}
