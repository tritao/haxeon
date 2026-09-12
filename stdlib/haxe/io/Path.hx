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

	static function lastSeparator(path:String):Int {
		var slash = path.lastIndexOf("/"), backslash = path.lastIndexOf("\\");
		return slash > backslash ? slash : backslash;
	}
}
