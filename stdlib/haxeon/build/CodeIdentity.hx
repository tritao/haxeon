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
	static final nativeBuilds:Map<String, Null<String>> = [];

	/**
	 * A fingerprint of the module named `name` (its qualified module name, for example "machinekit.hobbing.HobMesh"): its own
	 * source, the source of everything it imports directly or indirectly, the compiler and the compile defines. Editing the
	 * module or anything it depends on changes it; editing any other module does not. Null for a module that is not part of
	 * the program.
	 */
	public static function ofModule(name:String):Null<String>
		return CodeIdentityTable.lookup(name);

	/**
	 * A fingerprint of the shared libraries of the native package `packageName` that this program loads (the content of
	 * every library the build published for it, beside the program under `native/<package>`). Null when the program has no
	 * such directory (a browser build, or a program run from somewhere else): callers must then not trust a cache.
	 */
	public static function nativeBuild(packageName:String):Null<String> {
		if (nativeBuilds.exists(packageName))
			return nativeBuilds.get(packageName);
		var result = computeNativeBuild(packageName);
		nativeBuilds.set(packageName, result);
		return result;
	}

	static function computeNativeBuild(packageName:String):Null<String> {
		#if wasm
		return null;
		#else
		var directory = Path.join([Path.directory(Sys.fullPath(Sys.programPath())), "native", packageName]);
		if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory))
			return null;
		var names = [
			for (name in FileSystem.readDirectory(directory))
				if (isLibrary(name)) name
		];
		if (names.length == 0)
			return null;
		names.sort(Reflect.compare);
		var text = "";
		for (name in names) {
			var digest = Sha256.make(File.getBytes(directory + "/" + name));
			var hex = "";
			for (index in 0...digest.length)
				hex += StringTools.hex(digest.get(index), 2);
			text += name + ":" + hex.toLowerCase() + "\n";
		}
		return Sha256.encode(text);
		#end
	}

	static function isLibrary(name:String):Bool
		return StringTools.endsWith(name, ".dll") || StringTools.endsWith(name, ".dylib") || StringTools.endsWith(name, ".so")
			|| name.indexOf(".so.") > 0;
}
