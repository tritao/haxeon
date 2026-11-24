package compiler;

/**
 * How strictly the null-safety checker treats `Null<T>`, as Haxe's `@:nullSafety(Mode)` names it (docs/reference/LANGUAGE_SUPPORT.md,
 * "Null safety"). `Warn` is no Haxe mode: it checks as `Strict` and reports what it finds as warnings, to migrate code to it.
 */
enum abstract NullSafetyMode(String) to String {
	var Off = "off";

	/** Narrowing a field survives calls, as in Haxe. */
	var Loose = "loose";

	/** A call forgets what was proved about fields, and a closure sees no narrowing of the locals it captures. */
	var Strict = "strict";

	/** As `Strict`, and a field other than a `final` one is never narrowed: another thread may change it. */
	var StrictThreaded = "strict-threaded";

	var Warn = "warn";

	/** The mode spelled `text` on a command line or in a manifest, or null. */
	public static function parse(text:String):Null<NullSafetyMode>
		return switch text {
			case "off": Off;
			case "loose": Loose;
			case "strict": Strict;
			case "strict-threaded": StrictThreaded;
			case "warn": Warn;
			default: null;
		};

	/** The spellings `parse` reads. */
	public static final NAMES = ["off", "loose", "strict", "strict-threaded", "warn"];
}

/**
 * Haxe's `nullSafety(path, mode, recursive)` (`haxe.macro.Compiler`): the classes and abstracts at `path` take `@:nullSafety(mode)`
 * as if declared with it, ahead of their own metadata. `path` is a package (`app.ui`), a module (`app.ui.Button`) or a type in a
 * module (`app.ui.Button.Style`); the empty path is every module. A package rule reaches its subpackages only when `recursive`,
 * as Haxe's global metadata does. The rules are compile options (`CompileOptions.nullSafety`): a project's setting becomes one
 * per package or top-level source entry, made by the build (`project.CompilerInputs`).
 */
class NullSafetyRule {
	public final path:String;
	public final mode:NullSafetyMode;
	public final recursive:Bool;

	public function new(path:String, mode:NullSafetyMode, recursive:Bool = true) {
		this.path = path;
		this.mode = mode;
		this.recursive = recursive;
	}

	/** The `--null-safety=` value: `MODE`, `MODE:PATH`, then `:shallow` for a rule that is not recursive. */
	public function argument():String
		return mode + (path == "" && recursive ? "" : ":" + path) + (recursive ? "" : ":shallow");

	/** The rule a `--null-safety=` value states, or null when it is malformed. */
	public static function parse(value:String):Null<NullSafetyRule> {
		var parts = value.split(":"), mode = NullSafetyMode.parse(parts[0]);
		if (mode == null || parts.length > 3 || (parts.length == 3 && parts[2] != "shallow"))
			return null;
		var path = parts.length > 1 ? parts[1] : "";
		if (path != "" && !~/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/.match(path))
			return null;
		return new NullSafetyRule(path, mode, parts.length < 3);
	}

	/**
	 * Whether the rule reaches the type `typeName` of module `modulePath` (dot paths), as Haxe matches a global metadata path: by the
	 * type's dot path, which is the module's when the type is named like its module (`full_dot_path2`). A lowercase last segment of
	 * the rule names a package, whose modules it reaches directly; deeper only when recursive.
	 */
	public function matches(modulePath:String, typeName:String):Bool {
		var moduleParts = modulePath.split("."),
			moduleName = moduleParts[moduleParts.length - 1],
			typePath = moduleName == typeName ? moduleParts : moduleParts.concat([typeName]),
			pattern = path == "" ? [] : path.split(".");
		return matchPath(typePath, pattern, recursive);
	}

	/** Haxe's `match_path`: `path` (a type's segments) against `pattern` (a rule's). */
	static function matchPath(path:Array<String>, pattern:Array<String>, recursive:Bool):Bool {
		var index = 0;
		while (true) {
			var remaining = path.length - index, patternRemaining = pattern.length - index;
			if (remaining == 0 && patternRemaining == 0)
				return true;
			// A package pattern always reaches the types of its own modules: `a.b` matches the type `a.b.Module`.
			if (remaining >= 2 && patternRemaining == 1 && isLowerIdent(pattern[index])
				&& !isLowerIdent(path[index + 1]))
				return path[index] == pattern[index];
			if (remaining == 1 && patternRemaining == 1 && pattern[index] == "")
				return true;
			if (patternRemaining == 0 || (patternRemaining == 1 && pattern[index] == ""))
				return recursive;
			if (remaining == 0)
				return false;
			if (path[index] != pattern[index])
				return false;
			index++;
		}
	}

	static function isLowerIdent(name:String):Bool {
		var index = 0;
		while (index < name.length && name.charCodeAt(index) == "_".code)
			index++;
		if (index >= name.length)
			return false;
		var code = name.charCodeAt(index);
		return code >= "a".code && code <= "z".code;
	}
}
