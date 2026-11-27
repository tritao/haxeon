package compiler.runtime;

/**
	Array methods implemented in Haxe by the stdlib class `haxeon.ArrayMethods`
	rather than by the compiler. The dependency scanner loads that module when a
	source calls one of these names, and the typer resolves array calls it does
	not implement natively to the class's generic functions.
**/
class ArrayLibrary {
	/** Keep in step with the functions in `stdlib/haxeon/ArrayMethods.hx`. */
	static final METHODS:Array<String> = ["filter", "map", "join", "lastIndexOf", "keyValueIterator"];

	public static function provides(methodName:String):Bool
		return METHODS.indexOf(methodName) >= 0;

	/** Whether the last part of the dotted `path` is one of these methods (`provides`), read in place. */
	public static function providesLastOf(path:String):Bool
		return endsWithMember(path, METHODS);

	/** Whether the last part of the dotted `path` is one of `members`, read in place. */
	public static function endsWithMember(path:String, members:Array<String>):Bool {
		for (method in members) {
			var dot = path.length - method.length - 1;
			if (dot >= 0 && StringTools.fastCodeAt(path, dot) == ".".code && StringTools.endsWith(path, method))
				return true;
		}
		return false;
	}
}
