package compiler;

/** Operations on canonical dot-separated compiler names. */
class QualifiedName {
	public static function parent(path:String):Null<String> {
		var cursor = path.length - 1;
		while (cursor >= 0) {
			if (path.charCodeAt(cursor) == 46)
				return path.substring(0, cursor);
			cursor--;
		}
		return null;
	}

	public static function parentOrEmpty(path:String):String {
		var value = parent(path);
		return value == null ? "" : value;
	}

	public static function first(path:String):String {
		var cursor = 0;
		while (cursor < path.length) {
			if (path.charCodeAt(cursor) == 46)
				return path.substring(0, cursor);
			cursor++;
		}
		return path;
	}

	public static function last(path:String):String {
		var cursor = path.length - 1;
		while (cursor >= 0) {
			if (path.charCodeAt(cursor) == 46)
				return path.substring(cursor + 1, path.length);
			cursor--;
		}
		return path;
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
}
