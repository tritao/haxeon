package compiler.core;

/**
 * The marker a name resolves to when imports make it ambiguous (see `compiler.semantic.ImportShadowing`), and the E1029
 * message for it. It has no dependencies, so `Diagnostic` can turn any diagnostic that would show a marker into E1029.
 */
class AmbiguousName {
	static inline final MARKER = "Ambiguous$";
	static inline final IMPORTS_MARKER = "AmbiguousImports$";
	static inline final SEPARATOR = "$$";

	/** A name that matches no declaration and records `name`, the type the package declares and the one an import brings in. */
	public static function marker(name:String, own:String, imported:String):String
		return MARKER + name + SEPARATOR + encode(own) + SEPARATOR + encode(imported);

	/** A name two imports of the same rank give to different types, `first` and `second` (`ModuleAnalyzer.importAliases`). */
	public static function importsMarker(name:String, first:String, second:String):String
		return IMPORTS_MARKER + name + SEPARATOR + encode(first) + SEPARATOR + encode(second);

	/** Whether `name` is a marker rather than a declaration. */
	public static function isMarker(name:Null<String>):Bool
		return name != null && (StringTools.startsWith(name, MARKER) || StringTools.startsWith(name, IMPORTS_MARKER));

	/** The E1029 message for the first marker in `text`, or null when it has none. */
	public static function describe(text:String):Null<String> {
		var imports = text.indexOf(IMPORTS_MARKER);
		if (imports >= 0) {
			var parts = markerParts(text, imports + IMPORTS_MARKER.length);
			return parts == null ? null
				: 'Type name "${parts[0]}" is ambiguous: imports bring in both ${decode(parts[1])} and ${decode(parts[2])}; import the one you mean by name, or give one an alias';
		}
		var start = text.indexOf(MARKER);
		if (start < 0)
			return null;
		var parts = markerParts(text, start + MARKER.length);
		if (parts == null)
			return null;
		return 'Type name "${parts[0]}" is ambiguous: this package declares ${decode(parts[1])}, and an import of a whole module or package also brings in ${decode(parts[2])}; import the one you mean by name';
	}

	/** The name and the two candidates of the marker whose body starts at `start`, or null when it is malformed. */
	static function markerParts(text:String, start:Int):Null<Array<String>> {
		var end = start;
		while (end < text.length && isMarkerCharacter(StringTools.fastCodeAt(text, end)))
			end++;
		var parts = text.substring(start, end).split(SEPARATOR);
		return parts.length == 3 ? parts : null;
	}

	static inline function isMarkerCharacter(code:Int):Bool
		return code == "$".code
			|| code == "_".code
			|| (code >= "a".code && code <= "z".code)
			|| (code >= "A".code && code <= "Z".code)
			|| (code >= "0".code && code <= "9".code);

	/** Declaration paths contain dots, which would split a marker into path segments. */
	static function encode(path:String):String
		return path.split(".").join("$");

	static function decode(encoded:String):String
		return encoded.split("$").join(".");
}
