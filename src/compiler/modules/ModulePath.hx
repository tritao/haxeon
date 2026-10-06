package compiler.modules;

/** Canonicalizes source file paths into dot-separated module identities. */
class ModulePath {
	/** Package portion of a source module's canonical name. */
	public static function packageName(path:String):Null<String> {
		var separator = path.lastIndexOf(".");
		return separator <= 0 ? null : path.substring(0, separator);
	}

	public static function fromFile(path:String):String {
		var start = 0, end = path.length;
		while (start + 1 < end && path.charCodeAt(start) == 46 && isSeparator(path.charCodeAt(start + 1)))
			start += 2;
		if (end - start >= 3 && path.charCodeAt(end - 3) == 46 && path.charCodeAt(end - 2) == 104 && path.charCodeAt(end - 1) == 120)
			end -= 3;
		var result = "", segment = "";
		for (cursor in start...end) {
			var code = path.charCodeAt(cursor);
			if (isSeparator(code)) {
				if (segment.length > 0) {
					result += (result.length == 0 ? "" : ".") + segment;
					segment = "";
				}
			} else
				segment += String.fromCharCode(code);
		}
		if (segment.length > 0)
			result += (result.length == 0 ? "" : ".") + segment;
		return result;
	}

	static function isSeparator(code:Int):Bool
		return code == 47 || code == 92;
}
