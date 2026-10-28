package compiler.abi;

/**
 * Names a running module's functions move to when a build gives their name or slot to something else, while closures the
 * running program made may still call them: a lambda whose name a sibling takes (`LambdaAlignment`), and a function whose
 * signature changed, which leaves its slot behind (`HlModuleAssembler`). No build ever names a function like this, so nothing
 * is compared with a retired function or patched into it, and a fresh module drops them all (`HlFunctionCache.dropRetired`).
 */
class RetiredName {
	static inline final MARK:String = "~retired";

	/** The name a running lambda at `ordinal` of `group` takes; `tag` keeps the names different builds retire apart. */
	public static function lambda(group:String, ordinal:Int, tag:String):String
		return group + MARK + tag + "#" + ordinal;

	/** The name function `name` leaves in the slot it had when its signature changes. */
	public static function movedFunction(name:String, tag:String):String
		return name + MARK + tag;

	public static function is(name:String):Bool
		return name.indexOf(MARK) >= 0;

	/** The function `name` was moved away from (`movedFunction`), or null when `name` is not such a name. */
	public static function movedFrom(name:String):Null<String> {
		var at = name.lastIndexOf(MARK);
		if (at <= 0)
			return null;
		var tag = name.substr(at + MARK.length);
		if (tag.length == 0)
			return null;
		for (index in 0...tag.length)
			if (tag.charCodeAt(index) < "0".code || tag.charCodeAt(index) > "9".code)
				return null;
		return name.substr(0, at);
	}
}
