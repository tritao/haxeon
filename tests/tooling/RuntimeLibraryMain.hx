import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import tools.RuntimeLibrary;

/**
 * `tools.RuntimeLibrary`: finding that the built `haxeon_runtime.hdll` lacks natives the runtime sources define, before a program
 * dies on starting with "Failed to load function". Covers the source and symbol parsing, the whole check on a temporary checkout
 * (older library, current library, no library, no sources, the skip switch, the message) and the real sources against the real
 * library with one symbol removed.
 */
class RuntimeLibraryMain {
	static var checks = 0;

	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
		checks++;
	}

	static function same(actual:String, expected:String, message:String):Void check(actual == expected, message + ": " + actual + " vs " + expected);

	/** A fake library: NUL-separated symbol names, as a symbol table holds them. */
	static function library(symbols:Array<String>):Bytes {
		var out = new haxe.io.BytesOutput();
		out.writeByte(0);
		for (symbol in symbols) {
			out.writeString(symbol);
			out.writeByte(0);
		}
		return out.getBytes();
	}

	static function write(path:String, text:String):Void {
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, text);
	}

	static function directories(path:String):Void {
		var parent = Path.directory(path);
		if (parent != path && parent != "" && !FileSystem.exists(parent))
			directories(parent);
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}

	static function main():Void {
		// Source parsing: the natives DEFINE_PRIM declares, once each, in order, whatever the return type looks like.
		var defined = RuntimeLibrary.definedIn([
			"DEFINE_PRIM(_BOOL,__dir_watch_add,_BYTES _BYTES _BOOL)\nDEFINE_PRIM(_ABSTRACT(ereg), __regexp_new, _STRING _STRING)\n",
			"// DEFINE_PRIM is mentioned here\nDEFINE_PRIM(_STRING,__reflect_class_name,_DYN);\nDEFINE_PRIM(_BOOL,__dir_watch_add,_BYTES)\n"
		]);
		same(defined.join(","), "__dir_watch_add,__regexp_new,__reflect_class_name", "natives defined by the sources, each once");
		check(RuntimeLibrary.definedIn([]).length == 0, "no sources define nothing");

		// Symbol parsing: hlp_<name> after a NUL, with or without a leading underscore; other names are not natives.
		var exported = RuntimeLibrary.exportedNatives(library(["hlp___dir_watch_add", "realtime___dir_watch_add", "_hlp___regexp_new", "hlp_", "xhlp_wrong", "hl_regexp_new_options"]));
		check(exported.exists("__dir_watch_add"), "an hlp_ symbol is a native");
		check(exported.exists("__regexp_new"), "a leading underscore is allowed (Mach-O)");
		check(!exported.exists("wrong"), "a name that merely contains hlp_ is not one");
		check(!exported.exists("__reflect_class_name"), "a native that is not there is not found");
		check(RuntimeLibrary.exportedNatives(Bytes.alloc(0)).keys().hasNext() == false, "an empty file exports nothing");
		check(RuntimeLibrary.exportedNatives(Bytes.ofString("hlp")).keys().hasNext() == false, "a tiny file exports nothing");
		same(RuntimeLibrary.missingFrom(defined, library(["hlp___dir_watch_add", "hlp___regexp_new"])).join(","), "__reflect_class_name", "the missing native is named");
		check(RuntimeLibrary.missingFrom(defined, library(["hlp___dir_watch_add", "hlp___regexp_new", "hlp___reflect_class_name"])).length == 0, "a complete library lacks nothing");

		// The whole check on a temporary checkout.
		var root = FileSystem.fullPath(".") + "/out/runtime-library-test-" + Std.random(0x3fffffff);
		directories(root);
		var hdll = root + "/out/haxeon_runtime.hdll";
		check(RuntimeLibrary.missing(root).length == 0, "no sources and no library: nothing to compare");
		write(root + "/native/runtime.c", "DEFINE_PRIM(_I32,__a,_NO_ARG)\n");
		write(root + "/native/runtime/more.c", "DEFINE_PRIM(_I32,__b,_NO_ARG)\nDEFINE_PRIM(_I32,__c,_NO_ARG)\n");
		write(root + "/native/runtime/notes.txt", "DEFINE_PRIM(_I32,__ignored,_NO_ARG)\n");
		same(RuntimeLibrary.definedNatives(root).join(","), "__a,__b,__c", "runtime.c, then runtime/*.c in name order, .c files only");
		check(RuntimeLibrary.missing(root).length == 0, "sources but no library built yet: nothing to compare");
		directories(root + "/out");
		File.saveBytes(hdll, library(["hlp___a", "hlp___b"]));
		var lacking = RuntimeLibrary.missing(root);
		same(lacking.join(","), "__c", "an older library lacks the newer native");
		var text = RuntimeLibrary.describe(root, lacking);
		check(text.indexOf(hdll) >= 0 && text.indexOf("out of date") >= 0 && text.indexOf("__c") >= 0 && text.indexOf("lacks 1 function ") >= 0
			&& text.indexOf("scripts/build-native.sh") >= 0, "the message names the library, the function and the rebuild command: " + text);
		var long = RuntimeLibrary.describe(root, ["__1", "__2", "__3", "__4", "__5", "__6"]);
		check(long.indexOf("lacks 6 functions") >= 0 && long.indexOf("__4, ...") >= 0 && long.indexOf("__5") < 0, "a long list is cut short with its count: " + long);
		var thrown = "";
		try
			RuntimeLibrary.requireCurrent(root)
		catch (error:Dynamic)
			thrown = Std.string(error);
		check(thrown.indexOf("out of date") >= 0, "requireCurrent refuses an older library");
		Sys.putEnv("HAXEON_SKIP_RUNTIME_CHECK", "1");
		RuntimeLibrary.requireCurrent(root);
		check(RuntimeLibrary.skipped(), "HAXEON_SKIP_RUNTIME_CHECK=1 turns the check off");
		Sys.putEnv("HAXEON_SKIP_RUNTIME_CHECK", "");
		check(!RuntimeLibrary.skipped(), "an empty value does not");
		File.saveBytes(hdll, library(["hlp___a", "hlp___b", "hlp___c", "hlp___extra_not_in_sources"]));
		check(RuntimeLibrary.missing(root).length == 0, "a library with extra natives is current");
		RuntimeLibrary.requireCurrent(root);
		checks++;

		// The real sources against the real library, with one native taken out: exactly that one is reported.
		var home = Sys.getEnv("HAXEON_HOME");
		if (home == null || home == "")
			home = FileSystem.fullPath(".");
		var real = RuntimeLibrary.libraryPath(home);
		if (FileSystem.exists(real) && RuntimeLibrary.definedNatives(home).length > 0) {
			var realDefined = RuntimeLibrary.definedNatives(home);
			check(realDefined.length > 600 && realDefined.indexOf("__reflect_class_name") >= 0, "the real sources define their natives: " + realDefined.length);
			var bytes = File.getBytes(real);
			var current = RuntimeLibrary.missingFrom(realDefined, bytes);
			if (current.length == 0) {
				var needle = Bytes.ofString("hlp___reflect_class_name");
				var damaged = bytes.sub(0, bytes.length);
				var found = 0;
				for (start in 0...(damaged.length - needle.length)) {
					var hit = true;
					for (offset in 0...needle.length)
						if (damaged.get(start + offset) != needle.get(offset)) {
							hit = false;
							break;
						}
					if (hit) {
						damaged.set(start, 0x78); // "xlp___reflect_class_name": no longer a native
						found++;
					}
				}
				check(found >= 1, "the real library exports __reflect_class_name");
				same(RuntimeLibrary.missingFrom(realDefined, damaged).join(","), "__reflect_class_name", "the real library with that symbol taken out lacks exactly it");
			} else
				Sys.println("note: the library at " + real + " is out of date (lacks " + current.join(", ") + "); the real-library check was skipped");
		} else
			Sys.println("note: no built runtime library or no runtime sources here; the real-library check was skipped");

		Sys.println("runtime library tests: " + checks + " checks passed");
	}
}
