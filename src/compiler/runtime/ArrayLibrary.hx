package compiler.runtime;

/**
	Array methods implemented in Haxe by the stdlib class `haxeon.ArrayMethods`
	rather than by the compiler. The dependency scanner loads that module when a
	source calls one of these names, and the typer resolves array calls it does
	not implement natively to the class's generic functions.
**/
class ArrayLibrary {
	public static inline var CLASS_NAME = "haxeon.ArrayMethods";

	/** Keep in step with the functions in `stdlib/haxeon/ArrayMethods.hx`. */
	static final METHODS:Array<String> = ["filter", "map", "join", "lastIndexOf"];

	public static function provides(methodName:String):Bool
		return METHODS.indexOf(methodName) >= 0;
}
