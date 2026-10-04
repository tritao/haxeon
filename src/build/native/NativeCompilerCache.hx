package build.native;

import haxe.io.Path;
import sys.FileSystem;

/**
 * ccache for the native compiles of CMake packages, used when it is installed (`HAXEON_CCACHE=0` turns it off).
 *
 * ccache keys a compile by what it is given, which includes absolute paths, so the same source built in another checkout or
 * worktree is a miss. Telling ccache the directory the project and the package's sources share as its base directory makes it
 * key every path under it by its path relative to the compile's working directory, and `CCACHE_NOHASHDIR` keeps the working
 * directory itself out of the key. A checkout in another place then reuses the objects of the first (a cold build of the app:
 * 568 compiles, 567 from the cache). Paths outside it, such as a prebuilt OpenCASCADE, stay absolute, which is right as they
 * are shared. The project's own directory is not enough: the app's native sources are in sibling kits.
 */
class NativeCompilerCache {
	/** The ccache executable to launch compilers through, or null when it is turned off or not installed. */
	public static function executable():Null<String> {
		if (Sys.getEnv("HAXEON_CCACHE") == "0" || Sys.systemName() == "Windows")
			return null;
		var search = Sys.getEnv("PATH");
		if (search == null)
			return null;
		for (directory in search.split(":")) {
			if (directory.length == 0)
				continue;
			var candidate = Path.join([directory, "ccache"]);
			if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate))
				return candidate;
		}
		return null;
	}

	/** CMake arguments that route C and C++ compiles through `ccache`. */
	public static function configureArguments(ccache:Null<String>):Array<String>
		return ccache == null ? [] : [
			"-DCMAKE_C_COMPILER_LAUNCHER=" + ccache,
			"-DCMAKE_CXX_COMPILER_LAUNCHER=" + ccache
		];

	/**
	 * The environment ccache needs to key the compiles of a package whose CMake sources are in `source` independently of where
	 * the checkout is: the base directory is what `projectRoot` and `source` share, which is the checkout when the project and
	 * its native packages are kits of one repository, whichever of them the project is in.
	 */
	public static function environment(ccache:Null<String>, projectRoot:String, source:String):Map<String, String> {
		var result:Map<String, String> = [];
		if (ccache != null) {
			result.set("CCACHE_BASEDIR", commonDirectory(projectRoot, source));
			result.set("CCACHE_NOHASHDIR", "1");
		}
		return result;
	}

	/** The deepest directory that contains both paths. */
	public static function commonDirectory(first:String, second:String):String {
		var left = Path.normalize(first).split("/"),
			right = Path.normalize(second).split("/"),
			shared:Array<String> = [];
		for (index in 0...(left.length < right.length ? left.length : right.length)) {
			if (left[index] != right[index])
				break;
			shared.push(left[index]);
		}
		var result = shared.join("/");
		return result.length == 0 ? "/" : result;
	}
}
