package compiler.semantic;

/**
 * The names of the functions a lambda is compiled to: `$lambda:<enclosing>:<identity>`, where `<enclosing>` is the name of the
 * function or lambda it is written in and `<identity>` the one the parser gave it, `<member>#<anchor>#<ordinal>` (see
 * `Parser.openLambda`): the class member or module function it is written in, where in that body it is written (the variable
 * or field it is assigned to and the calls it is an argument of, like `hover=/resourceState(1)`), and its position among the
 * lambdas written directly in the same body at the same anchor. A lambda with no anchor is `<member>#<ordinal>`. Code that moves
 * around a lambda, and lambdas added or removed at other anchors, leave its name alone, so a running module can adopt the edit
 * as a patch; only adding or removing an earlier lambda at the same anchor renames it. The member keeps lambdas from different
 * declarations apart when they compile into one function (field initializers into the class initializer or constructor).
 *
 * A lambda that captures variables carries a hash of its captures before the ordinal (`withCaptures`), so it is a different
 * function, with a different environment type, once its captures change.
 *
 * A lambda is a function of its own, but it is typed, cached and invalidated with the function it is written in, and the
 * stored state that refers to it (call graphs, purity records) is keyed by name. This is the one place that knows the
 * format: build names with `of` and take them apart with `enclosing` and `outermost`, never by matching on the text.
 * The enclosing name can contain colons itself (a generic specialization, another lambda), so it is everything between the
 * prefix and the last colon. An identity contains no colon.
 */
class LambdaName {
	static inline final PREFIX = "$lambda:";

	public static function of(enclosing:String, identity:String):String
		return PREFIX + enclosing + ":" + identity;

	/**
	 * `identity` for a lambda that captures `captures` (each `<name>:<storage type>`, in environment order): a hash of them goes
	 * before the ordinal. A lambda that captures nothing keeps its identity.
	 */
	public static function withCaptures(identity:String, captures:Array<String>):String {
		if (captures.length == 0)
			return identity;
		var hash:Int = cast 0x811C9DC5, key = captures.join(",");
		for (index in 0...key.length)
			hash = (hash ^ key.charCodeAt(index)) * 16777619;
		var ordinal = identity.lastIndexOf("#");
		return identity.substring(0, ordinal) + "@" + StringTools.hex(hash & 0x7FFFFFFF, 8) + identity.substring(ordinal);
	}

	public static inline function is(name:String):Bool
		return StringTools.startsWith(name, PREFIX);

	/** The function or lambda `name` is written in, or null when `name` is not a lambda. */
	public static function enclosing(name:String):Null<String> {
		if (! is(name))
			return null;
		var end = name.lastIndexOf(":");
		return end <= PREFIX.length ? null : name.substring(PREFIX.length, end);
	}

	/** The function that contains `name` once every level of lambda nesting is removed; `name` itself when it is not a lambda. */
	public static function outermost(name:String):String {
		var outer = enclosing(name);
		while (outer != null) {
			name = outer;
			outer = enclosing(name);
		}
		return name;
	}
}
