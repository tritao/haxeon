package haxeon.build;

import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * Which code and native libraries a running program was built from, for caches whose entries are only valid for the code that
 * computed them.
 */
class CodeIdentity {
	/**
	 * A fingerprint of the module named `name` (its qualified module name, for example "machinekit.hobbing.HobMesh"): its own
	 * source, the source of everything it imports directly or indirectly, the compiler and the compile defines. Editing the
	 * module or anything it depends on changes it; editing any other module does not. Null for a module that is not part of
	 * the program.
	 */
	public static function ofModule(name:String):Null<String>
		return CodeIdentityTable.lookup(name);

	/**
	 * The files of the shared libraries this process has loaded whose names start with `namePrefix`, as the loader maps them
	 * (wherever they were found, sorted). Call it after the first call into the library, which is what loads it. Empty where the
	 * loaded libraries cannot be listed (anything but Linux).
	 */
	public static function mappedLibraries(namePrefix:String):Array<String> {
		#if wasm
		return [];
		#else
		if (Sys.systemName() != "Linux" || !FileSystem.exists("/proc/self/maps"))
			return [];
		var seen = new Map<String, Bool>();
		var paths:Array<String> = [];
		for (line in File.getContent("/proc/self/maps").split("\n")) {
			var slash = line.indexOf("/");
			if (slash < 0)
				continue;
			var path = line.substr(slash);
			if (!StringTools.startsWith(Path.withoutDirectory(path), namePrefix) || seen.exists(path) || !FileSystem.exists(path))
				continue;
			seen.set(path, true);
			paths.push(path);
		}
		paths.sort(Reflect.compare);
		return paths;
		#end
	}

	/**
	 * A fingerprint of the content of the shared libraries this process has loaded whose file names start with `namePrefix`
	 * (their names and SHA-256 digests, not their locations), so a program run from a temporary directory with its libraries found
	 * through the library path is identified the same as one run beside them. Null where none can be listed.
	 */
	public static function loadedLibrariesContent(namePrefix:String):Null<String> {
		var paths = mappedLibraries(namePrefix);
		if (paths.length == 0)
			return null;
		var entries = [for (path in paths) Path.withoutDirectory(path) + ":" + fileDigest(path)];
		entries.sort(Reflect.compare);
		return Sha256.encode(entries.join("\n"));
	}

	public static function fileDigest(path:String):String {
		var digest = Sha256.make(File.getBytes(path)), hex = "";
		for (index in 0...digest.length)
			hex += StringTools.hex(digest.get(index), 2);
		return hex.toLowerCase();
	}
}
