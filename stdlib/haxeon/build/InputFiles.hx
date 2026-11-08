package haxeon.build;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/**
 * The files a program reads while it runs, for caches whose entries are only valid while those files are unchanged.
 *
 * `sys.io.File` and `sys.FileSystem` call into this module, so every read and query a program makes through the standard
 * library is noted, with no call site to forget: a file's bytes (or text), that a path exists or is a directory, a directory's
 * listing, and that a path was missing (creating it later changes the answer). Nothing is noted unless the program was
 * started with `--record-inputs=FILE`, so a build tool or the compiler pays one boolean test. Files the program writes are its output, not its input, and are left out, as are the
 * kernel's own cache directory (`ignorePrefix`) and `/proc`, `/sys` and `/dev`. Native code that opens a file itself is not seen;
 * CadKit's STEP import reads the file in Haxe first, which is.
 *
 * `save` writes the list as JSON, `[path, kind, digest]` per entry, and `unchanged` asks the same questions again.
 */
class InputFiles {
	/** The argument that turns recording on, from the first instruction of the program: `--record-inputs=FILE`. */
	public static inline final FLAG = "--record-inputs=";

	// No initializers: reads happen during other classes' static initialization, which may run before this class's.
	static var resolved:Bool;
	static var on:Bool;
	static var target:Null<String>;
	static var entries:Null<Array<Array<String>>>;
	static var noted:Null<Map<String, Bool>>;
	static var written:Null<Map<String, Bool>>;
	static var ignored:Null<Array<String>>;

	/** Whether this run records its reads: the program was started with the flag. Decided on first use, whenever that is. */
	public static function isRecording():Bool {
		if (!resolved) {
			resolved = true;
			for (argument in Sys.args())
				if (StringTools.startsWith(argument, FLAG)) {
					target = argument.substr(FLAG.length);
					on = true;
					entries = [];
					noted = [];
					written = [];
					ignored = ["/proc/", "/sys/", "/dev/"];
				}
		}
		return on;
	}

	/** The program's arguments without the recording flag. */
	public static function arguments():Array<String>
		return [for (argument in Sys.args()) if (!StringTools.startsWith(argument, FLAG)) argument];

	/** Reads below `prefix` (a directory) are not inputs: a cache's own files. */
	public static function ignorePrefix(prefix:String):Void {
		if (isRecording() && ignored != null)
			ignored.push(absolute(prefix) + "/");
	}

	/** One file that is not an input: the document a runner hands the program, already part of the cache's key. */
	public static function ignoreFile(path:String):Void {
		if (isRecording() && ignored != null)
			ignored.push(absolute(path));
	}

	public static function bytesRead(path:String, bytes:Bytes):Void
		note(path, "bytes", digest(bytes));

	public static function textRead(path:String, text:String):Void
		note(path, "text", digest(Bytes.ofString(text)));

	/** A read that failed: the file is missing (or unreadable) now, and appearing later must invalidate. */
	public static function readFailed(path:String):Void {
		note(path, "bytes", "missing");
		note(path, "text", "missing");
	}

	public static function existsQuery(path:String, result:Bool):Void
		note(path, "exists", result ? "1" : "0");

	public static function directoryQuery(path:String, result:Bool):Void
		note(path, "directory", result ? "1" : "0");

	public static function listingRead(path:String, names:Array<String>):Void {
		var sorted = names.copy();
		sorted.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		note(path, "listing", digest(Bytes.ofString(sorted.join("\n"))));
	}

	public static function listingFailed(path:String):Void
		note(path, "listing", "missing");

	/** The program wrote `path`: whatever it reads there afterwards, or before, is its own output. */
	public static function wrote(path:String):Void {
		if (isRecording() && written != null)
			written.set(absolute(path), true);
	}

	/** The list of everything noted and not written, as JSON. */
	public static function report():String {
		var list:Array<Array<String>> = [];
		if (entries != null && written != null)
			for (entry in entries)
				if (!written.exists(entry[0]))
					list.push(entry);
		return Json.stringify(list);
	}

	/** Writes the list to the file the flag named (nothing when this run is not recording). Call it last. */
	public static function save():Void {
		if (!isRecording() || target == null)
			return;
		var text = report(), path:String = target;
		on = false;
		File.saveContent(path, text);
	}

	/** Whether every noted file still answers as it did. Any doubt (an unreadable list) is a no. */
	public static function unchanged(text:String):Bool {
		try {
			var list:Array<Array<String>> = Json.parse(text);
			for (entry in list)
				if (answer(entry[0], entry[1]) != entry[2])
					return false;
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	static function answer(path:String, kind:String):String {
		try {
			return switch kind {
				case "bytes": FileSystem.exists(path) && !FileSystem.isDirectory(path) ? digest(File.getBytes(path)) : "missing";
				case "text": FileSystem.exists(path) && !FileSystem.isDirectory(path) ? digest(Bytes.ofString(File.getContent(path))) : "missing";
				case "exists": FileSystem.exists(path) ? "1" : "0";
				case "directory": FileSystem.exists(path) && FileSystem.isDirectory(path) ? "1" : "0";
				case "listing":
					if (!FileSystem.exists(path) || !FileSystem.isDirectory(path)) "missing" else {
						var names = FileSystem.readDirectory(path);
						names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
						digest(Bytes.ofString(names.join("\n")));
					}
				default: "unknown kind";
			}
		} catch (_:Dynamic) {
			return "unreadable";
		}
	}

	static function note(path:String, kind:String, answer:String):Void {
		if (!isRecording() || ignored == null || noted == null || entries == null)
			return;
		var full = absolute(path);
		for (prefix in ignored)
			if (StringTools.startsWith(full, prefix))
				return;
		var key = kind + "\n" + full;
		if (noted.exists(key))
			return;
		noted.set(key, true);
		entries.push([full, kind, answer]);
	}

	static function absolute(path:String):String {
		if (StringTools.startsWith(path, "/"))
			return normalize(path);
		return normalize(Sys.getCwd() + "/" + path);
	}

	/** Removes `.`, `..` and repeated separators so that one file has one name. */
	static function normalize(path:String):String {
		var parts:Array<String> = [];
		for (part in path.split("/")) {
			if (part == "" || part == ".")
				continue;
			if (part == "..") {
				if (parts.length > 0)
					parts.pop();
				continue;
			}
			parts.push(part);
		}
		return "/" + parts.join("/");
	}

	static function digest(bytes:Bytes):String {
		var raw = Sha256.make(bytes), hex = new StringBuf();
		for (index in 0...raw.length)
			hex.add(StringTools.hex(raw.get(index), 2).toLowerCase());
		return hex.toString();
	}
}
