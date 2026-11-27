package compiler.runtime;

/**
	Map methods implemented in Haxe by the stdlib class `haxeon.MapMethods` rather than by the compiler, as `ArrayLibrary` does
	for arrays: the dependency scanner loads that module when a source calls one of these names, and the typer resolves map calls
	it does not implement natively to the class's generic functions.
**/
class MapLibrary {
	/** Keep in step with the functions in `stdlib/haxeon/MapMethods.hx`. */
	static final METHODS:Array<String> = ["keyValueIterator"];

	public static function provides(methodName:String):Bool
		return METHODS.indexOf(methodName) >= 0;

	/** Whether the last part of the dotted `path` is one of these methods (`provides`), read in place. */
	public static function providesLastOf(path:String):Bool
		return ArrayLibrary.endsWithMember(path, METHODS);
}
