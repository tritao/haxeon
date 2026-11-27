package haxe.io;

/** Paths taken apart and put together as text, with `/` or `\` as separators, without looking at the filesystem. */
class Path {
	/**
	 * `path` without its last segment and the separator before it: `"a/b"` for `"a/b/c"`, `"/"` for `"/c"`, `""` when
	 * it has no separator.
	 */
	public static function directory(path:String):String {
		var separator = lastSeparator(path);
		if (separator < 0)
			return "";
		if (separator == 0)
			return path.substr(0, 1);
		return path.substr(0, separator);
	}

	/**
	 * `path` without the extension of its last segment (from that segment's last "."). As in Haxe, "." and ".." are directories:
	 * they come back as "./" and "../".
	 */
	public static function withoutExtension(path:String):String {
		if (path == "." || path == "..")
			return path + "/";
		var dot = path.lastIndexOf(".");
		return dot > lastSeparator(path) ? path.substr(0, dot) : path;
	}

	/** The last segment of `path`, after its last separator: `"c"` for `"a/b/c"`. */
	public static function withoutDirectory(path:String):String {
		var separator = lastSeparator(path);
		return separator < 0 ? path : path.substr(separator + 1);
	}

	/**
	 * `paths` joined with `/` and normalized, skipping the empty ones. An absolute path restarts the result from
	 * itself.
	 */
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

	/**
	 * `path` with `/` separators, without empty and `.` segments, and with each `..` removing the segment before it (an
	 * absolute path drops a `..` at its root). A drive letter is kept; `""` becomes `"."`.
	 */
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

	/** `path` ending in a separator: the one it already uses last, or "/"; "" becomes "/". */
	public static function addTrailingSlash(path:String):String {
		if (path.length == 0)
			return "/";
		var slash = path.lastIndexOf("/"), backslash = path.lastIndexOf("\\");
		if (slash < backslash)
			return backslash != path.length - 1 ? path + "\\" : path;
		return slash != path.length - 1 ? path + "/" : path;
	}

	/** `path` without the separators it ends in. */
	public static function removeTrailingSlashes(path:String):String {
		var end = path.length;
		while (end > 0 && (path.charCodeAt(end - 1) == "/".code || path.charCodeAt(end - 1) == "\\".code))
			end--;
		return path.substr(0, end);
	}

	/** The extension of the last segment, after its last ".", or "" when it has none. "." and ".." have none. */
	public static function extension(path:String):String {
		var file = withoutDirectory(path);
		if (file == "." || file == "..")
			return "";
		var dot = file.lastIndexOf(".");
		return dot < 0 ? "" : file.substr(dot + 1);
	}

	/** `path` with the extension of its last segment replaced by `ext`, or given one. */
	public static function withExtension(path:String, ext:String):String
		return withoutExtension(path) + "." + ext;

	/** Whether `path` starts at a root: with `/` or `\`, or with a drive letter like `C:`. */
	public static function isAbsolute(path:String):Bool
		return path.length > 0
			&& (path.charCodeAt(0) == "/".code || path.charCodeAt(0) == "\\".code || path.length > 2
			&& path.charCodeAt(1) == ":".code);

	static function lastSeparator(path:String):Int {
		var slash = path.lastIndexOf("/"), backslash = path.lastIndexOf("\\");
		return slash > backslash ? slash : backslash;
	}
}
