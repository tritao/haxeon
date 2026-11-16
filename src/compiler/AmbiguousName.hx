package compiler;

/**
 * The marker a name resolves to when imports make it ambiguous (see `compiler.semantic.ImportShadowing`), and the E1029
 * message for it. It has no dependencies, so `Diagnostic` can turn any diagnostic that would show a marker into E1029.
 */
class AmbiguousName {
	public static inline final CODE = "E1029";
	static inline final MARKER = "Ambiguous$";
	static inline final SEPARATOR = "$$";

	/** A name that matches no declaration and records `name`, the type the package declares and the one an import brings in. */
	public static function marker(name:String, own:String, imported:String):String
		return MARKER + name + SEPARATOR + encode(own) + SEPARATOR + encode(imported);

	/** The E1029 message for the first marker in `text`, or null when it has none. */
	public static function describe(text:String):Null<String> {
		var start = text.indexOf(MARKER);
		if (start < 0)
			return null;
		var end = start + MARKER.length;
		while (end < text.length && isMarkerCharacter(StringTools.fastCodeAt(text, end)))
			end++;
		var parts = text.substring(start + MARKER.length, end).split(SEPARATOR);
		if (parts.length != 3)
			return null;
		return 'Type name "${parts[0]}" is ambiguous: this package declares ${decode(parts[1])}, and an import of a whole module or package also brings in ${decode(parts[2])}; import the one you mean by name';
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
