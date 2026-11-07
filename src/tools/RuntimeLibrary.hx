package tools;

import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * Whether the built native runtime library (`out/haxeon_runtime.hdll`) has every native function the runtime sources define.
 *
 * A checkout that moves to newer sources keeps the library it built earlier, and a program that calls a native the old library
 * lacks fails only when it starts, with a bare "Failed to load function" from the VM. This compares the natives the sources define
 * (`DEFINE_PRIM(<type>, <name>, ...)` in native/runtime.c and native/runtime/*.c) with the `hlp_<name>` symbols the library exports. It reads
 * contents, not file times, so a checkout that scrambles times cannot fool it. It finds missing functions, not changed ones: a library
 * built from older sources that differs only in what a function does passes.
 */
class RuntimeLibrary {
	/** `HAXEON_SKIP_RUNTIME_CHECK=1` turns the check off (a runtime built or installed somewhere the sources do not describe). */
	public static function skipped():Bool {
		var value = Sys.getEnv("HAXEON_SKIP_RUNTIME_CHECK");
		return value != null && value != "" && value != "0";
	}

	public static function libraryPath(home:String):String
		return Path.join([home, "out", "haxeon_runtime.hdll"]);

	/** Natives the sources define, in source order; empty when this checkout has no runtime sources. */
	public static function definedNatives(home:String):Array<String> {
		var files = [Path.join([home, "native", "runtime.c"])];
		var directory = Path.join([home, "native", "runtime"]);
		if (FileSystem.exists(directory) && FileSystem.isDirectory(directory)) {
			var names = FileSystem.readDirectory(directory);
			names.sort(Reflect.compare);
			for (name in names)
				if (StringTools.endsWith(name, ".c"))
					files.push(Path.join([directory, name]));
		}
		return definedIn([for (file in files) if (FileSystem.exists(file)) File.getContent(file)]);
	}

	/** The native names `DEFINE_PRIM(<type>, <name>, <arguments>)` declares in each of `sources`. */
	public static function definedIn(sources:Array<String>):Array<String> {
		var pattern = ~/DEFINE_PRIM\(\s*_[A-Z0-9]+(?:\([^)]*\))?\s*,\s*(\w+)\s*,/g;
		var seen = new Map<String, Bool>(), result = [];
		for (source in sources) {
			var rest = source;
			while (pattern.match(rest)) {
				var name = pattern.matched(1);
				if (!seen.exists(name)) {
					seen.set(name, true);
					result.push(name);
				}
				rest = pattern.matchedRight();
			}
		}
		return result;
	}

	/** The `hlp_<name>` function names a library's bytes export (a NUL-terminated symbol, optionally with a leading underscore). */
	public static function exportedNatives(library:Bytes):Map<String, Bool> {
		var exported = new Map<String, Bool>(), length = library.length, index = 0;
		while (index + 4 <= length) {
			// A symbol starts after a NUL: skip to the next one so every token is looked at once.
			var start = index;
			if (library.get(start) == 0x5F)
				start++;
			if (start + 4 <= length && library.get(start) == 0x68 && library.get(start + 1) == 0x6C && library.get(start + 2) == 0x70 && library.get(start + 3) == 0x5F) {
				var end = start + 4;
				while (end < length && library.get(end) != 0)
					end++;
				exported.set(library.getString(start + 4, end - start - 4), true);
				index = end;
			} else {
				while (index < length && library.get(index) != 0)
					index++;
			}
			index++;
		}
		return exported;
	}

	/** The natives `defined` that `library` does not export. */
	public static function missingFrom(defined:Array<String>, library:Bytes):Array<String> {
		var exported = exportedNatives(library);
		return [for (name in defined) if (!exported.exists(name)) name];
	}

	/** Natives the sources define that the built library lacks; empty when it is current, absent, or this checkout has no sources. */
	public static function missing(home:String):Array<String> {
		var path = libraryPath(home);
		if (!FileSystem.exists(path))
			return [];
		var defined = definedNatives(home);
		return defined.length == 0 ? [] : missingFrom(defined, File.getBytes(path));
	}

	/** One line: which library, what it lacks, and how to rebuild it. */
	public static function describe(home:String, missing:Array<String>):String {
		var shown = missing.slice(0, 4).join(", ") + (missing.length > 4 ? ", ..." : "");
		return 'the native runtime library ${libraryPath(home)} is out of date: it lacks ${missing.length} function${missing.length == 1 ? "" : "s"} the runtime sources define ($shown). Rebuild it with: ${Path.join([home, "scripts", "build-native.sh"])}';
	}

	/** Throws `describe` when the library is out of date. */
	public static function requireCurrent(home:String):Void {
		if (skipped())
			return;
		var lacking = missing(home);
		if (lacking.length > 0)
			throw describe(home, lacking);
	}
}
