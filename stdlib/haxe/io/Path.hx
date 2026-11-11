package haxe.io;

/** Cross-platform lexical path operations with no filesystem access. */
class Path {
	public static function directory(path:String):String {
		var separator = lastSeparator(path);
		if (separator < 0)
			return "";
		if (separator == 0)
			return path.substr(0, 1);
		return path.substr(0, separator);
	}

	public static function withoutDirectory(path:String):String {
		var separator = lastSeparator(path);
		return separator < 0 ? path : path.substr(separator + 1);
	}

	/** The part after the last `.` of the file name, or `""` when it has none. */
	public static function extension(path:String):String {
		var dot = extensionDot(path);
		return dot < 0 ? "" : path.substr(dot + 1);
	}

	/** `path` without the file name's extension and its `.`. */
	public static function withoutExtension(path:String):String {
		var dot = extensionDot(path);
		return dot < 0 ? path : path.substr(0, dot);
	}

	/** `path` with its file name's extension replaced by, or extended with, `ext`. */
	public static function withExtension(path:String, ext:String):String
		return withoutExtension(path) + "." + ext;

	/** `path` ending in a separator: the last one it uses, or `/`. */
	public static function addTrailingSlash(path:String):String {
		if (path.length == 0)
			return "/";
		var slash = path.lastIndexOf("/"), backslash = path.lastIndexOf("\\");
		if (slash < backslash)
			return backslash == path.length - 1 ? path : path + "\\";
		return slash == path.length - 1 ? path : path + "/";
	}

	public static function join(paths:Array<String>):String {
		var result = "";
		for (path in paths) {
			if (path == "")
				continue;
			if (result == "" || isAbsolute(path))
				result = path;
			else
				result += "/" + path;
		}
		return normalize(result);
	}

	public static function normalize(path:String):String {
		if (path == "")
			return ".";
		var value = StringTools.replace(path, "\\", "/"), prefix = "", absolute = false;
		if (value.length >= 2 && value.charCodeAt(1) == ":".code) {
			prefix = value.substr(0, 2);
			value = value.substr(2);
		}
		if (StringTools.startsWith(value, "/")) {
			absolute = true;
			while (StringTools.startsWith(value, "/"))
				value = value.substr(1);
		}
		var parts:Array<String> = [];
		for (part in value.split("/")) {
			if (part == "" || part == ".")
				continue;
			if (part == ".." && parts.length > 0 && parts[parts.length - 1] != "..")
				parts.pop();
			else if (part != ".." || !absolute)
				parts.push(part);
		}
		var result = parts.join("/");
		if (absolute)
			result = "/" + result;
		result = prefix + result;
		return result == "" ? (absolute ? "/" : ".") : result;
	}

	public static function isAbsolute(path:String):Bool
		return path.length > 0
			&& (path.charCodeAt(0) == "/".code || path.charCodeAt(0) == "\\".code || path.length > 2 && path.charCodeAt(1) == ":".code);

	static function extensionDot(path:String):Int {
		var dot = path.lastIndexOf(".");
		return dot > lastSeparator(path) ? dot : -1;
	}

	static function lastSeparator(path:String):Int {
		var slash = path.lastIndexOf("/"), backslash = path.lastIndexOf("\\");
		return slash > backslash ? slash : backslash;
	}
}
