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
		if (end - start >= 3 && path.charCodeAt(end - 3) == 46 && path.charCodeAt(end - 2) == 104
			&& path.charCodeAt(end - 1) == 120)
			end -= 3;
		var segments:Array<String> = [], segmentStart = start;
		for (cursor in start...end + 1)
			if (cursor == end || isSeparator(path.charCodeAt(cursor))) {
				if (cursor > segmentStart)
					segments.push(path.substring(segmentStart, cursor));
				segmentStart = cursor + 1;
			}
		return segments.join(".");
	}

	/** The package a source declares (its leading `package a.b;`, after comments and a script's `#!` line), or "" for the root package. */
	public static function declaredPackage(text:String):String {
		var index = StringTools.startsWith(text, "#!") ? text.indexOf("\n") : 0, length = text.length;
		if (index < 0)
			return "";
		while (index < length) {
			var code = text.charCodeAt(index);
			if (code == " ".code || code == "\t".code || code == "\n".code || code == "\r".code || code == 0xFEFF) {
				index++;
			} else if (code == "/".code && index + 1 < length && text.charCodeAt(index + 1) == "/".code) {
				while (index < length && text.charCodeAt(index) != "\n".code)
					index++;
			} else if (code == "/".code && index + 1 < length && text.charCodeAt(index + 1) == "*".code) {
				var end = text.indexOf("*/", index + 2);
				index = end < 0 ? length : end + 2;
			} else {
				break;
			}
		}
		if (text.substr(index, 7) != "package")
			return "";
		var after = index + 7;
		if (after < length) {
			var next = text.charCodeAt(after);
			if (next != " ".code && next != "\t".code && next != "\n".code && next != "\r".code && next != ";".code)
				return ""; // an identifier such as `packageName`, not the keyword
		}
		var end = text.indexOf(";", after);
		return end < 0 ? "" : StringTools.trim(text.substring(after, end));
	}

	/**
	 * The directory a package's folders start in, for a module in `directory` that declares `packageName` (dotted, "" for the root
	 * package): the source root its declaration implies, as a project's would be, "" when `directory` is the package's folders relative to
	 * the working directory. Null when the folders do not spell the package.
	 */
	public static function packageRoot(directory:String, packageName:String):Null<String> {
		if (packageName == "")
			return directory;
		var folders = directory.split("/"), parts = packageName.split(".");
		if (parts.length > folders.length || folders.slice(folders.length - parts.length).join("/") != parts.join("/"))
			return null;
		return folders.slice(0, folders.length - parts.length).join("/");
	}

	static function isSeparator(code:Int):Bool
		return code == 47 || code == 92;
}
