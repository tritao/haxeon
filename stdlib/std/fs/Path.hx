package std.fs;

/**
 * A path to a file or directory, kept normalized: separators are `/` (a Windows `\` becomes one), repeated ones and `.`
 * parts are dropped, and only the root keeps a trailing `/`. `..` stays as written, because what it reaches depends on
 * symbolic links the path passes through. The empty path is `.`. A `String` converts to a `Path` where one is expected,
 * so `Files.read("config.json")` needs no conversion; a path is joined with `join`, not built by concatenation.
 */
abstract Path(String) {
	inline function new(normalized:String)
		this = normalized;

	/** `text` as a path, normalized. */
	@:from public static function of(text:String):Path
		return new Path(normalize(text));

	/** Whether the path starts at a root: `/`, a Windows drive (`C:/`) or a network share (`//server/share`). */
	public function isAbsolute():Bool
		return rootLength(this) > 0;

	/** `other` beneath this path, or `other` itself when it is absolute. */
	public function join(other:Path):Path {
		var tail = other.toString();
		if (other.isAbsolute() || this == ".")
			return other;
		if (tail == ".")
			return new Path(this);
		return new Path(StringTools.endsWith(this, "/") ? this + tail : this + "/" + tail);
	}

	/** The directory that holds this path: `a/b` for `a/b/c`, `.` for `c`, null for a root and for `.`. */
	public function parent():Null<Path> {
		var root = rootLength(this);
		if (this == "." || root == this.length)
			return null;
		var slash = this.lastIndexOf("/");
		if (slash < root)
			return root > 0 ? new Path(this.substr(0, root)) : new Path(".");
		return new Path(this.substr(0, slash));
	}

	/** The last part of the path: `c` for `a/b/c`, `""` for a root. */
	public function name():String {
		if (rootLength(this) == this.length)
			return "";
		return this.substr(this.lastIndexOf("/") + 1);
	}

	/** The name's extension without its dot: `json` for `a/config.json`, `""` when there is none or the name starts with it. */
	public function extension():String {
		var name = name(), dot = name.lastIndexOf(".");
		return dot <= 0 ? "" : name.substr(dot + 1);
	}

	/** The path as text, with `/` separators. */
	@:to public inline function toString():String
		return this;

	static var windows:Null<Bool> = null;

	static function onWindows():Bool {
		if (windows == null)
			windows = Sys.systemName() == "Windows";
		return windows;
	}

	/** How many characters of the normalized `path` are its root: `/`, `C:/`, `//server/share/`, or none. */
	static function rootLength(path:String):Int {
		if (StringTools.startsWith(path, "//")) {
			var share = path.indexOf("/", 2);
			share = share < 0 ? -1 : path.indexOf("/", share + 1);
			return share < 0 ? path.length : share + 1;
		}
		if (StringTools.startsWith(path, "/"))
			return 1;
		if (onWindows() && path.length >= 3 && path.charAt(1) == ":" && path.charAt(2) == "/"
			&& isLetter(path.charCodeAt(0)))
			return 3;
		return 0;
	}

	static inline function isLetter(code:Null<Int>):Bool
		return code != null && (code >= "A".code && code <= "Z".code || code >= "a".code && code <= "z".code);

	static function normalize(text:String):String {
		var source = onWindows() ? StringTools.replace(text, "\\", "/") : text;
		// A network share's leading `//` is its root, not a repeated separator.
		var share = onWindows() && StringTools.startsWith(source, "//") && !StringTools.startsWith(source, "///");
		var absolute = StringTools.startsWith(source, "/");
		var parts:Array<String> = [];
		for (part in source.split("/"))
			if (part != "" && part != ".")
				parts.push(part);
		var joined = parts.join("/");
		if (share)
			return "//" + joined;
		if (absolute)
			return "/" + joined;
		if (joined == "")
			return ".";
		// A drive alone (`C:`) is relative to that drive's working directory; `C:/` is its root.
		if (rootLength(source.substr(0, 3)) == 3 && parts.length > 0 && parts[0].length == 2)
			return parts.length == 1 ? parts[0] + "/" : parts[0] + "/" + parts.slice(1).join("/");
		return joined;
	}
}
