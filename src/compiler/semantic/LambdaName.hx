package compiler.semantic;

/**
 * The names of the functions a lambda is compiled to: `$lambda:<enclosing>:<offset>`, where `<enclosing>` is the name of the
 * function or lambda it is written in and `<offset>` the position of the lambda in its source.
 *
 * A lambda is a function of its own, but it is typed, cached and invalidated with the function it is written in, and the
 * stored state that refers to it (call graphs, purity records) is keyed by name. This is the one place that knows the
 * format: build names with `of` and take them apart with `enclosing` and `outermost`, never by matching on the text.
 * The enclosing name can contain colons itself (a generic specialization, another lambda), so it is everything between the
 * prefix and the last colon.
 */
class LambdaName {
	static inline final PREFIX = "$lambda:";

	public static function of(enclosing:String, offset:Int):String
		return PREFIX + enclosing + ":" + offset;

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
