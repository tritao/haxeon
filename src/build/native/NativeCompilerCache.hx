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
 * are shared. The project's own directory is not enough: the app's native sources are in sibling kits. That reuse across
 * checkouts does not hold on Windows, which has no base directory (see `environment`).
 *
 * `CCACHE_DEPEND` has ccache take the files a compile reads from the compiler's dependency output rather than from the
 * preprocessed source. Otherwise a source whose preprocessed output names a file that is not there (HarfBuzz's generated
 * parsers carry `#line` markers for their Ragel grammars) is never cached, and its 11 s compile is repeated every build.
 */
class NativeCompilerCache {
	/**
	 * The ccache executable to launch compilers through, or null when it is turned off or not installed. On Windows only the
	 * one the bootstrap pins under `home`'s `.tools` is used, and only in an MSVC environment that names its toolset.
	 */
	public static function executable(?home:String):Null<String> {
		if (Sys.getEnv("HAXEON_CCACHE") == "0")
			return null;
		if (Sys.systemName() == "Windows") {
			if (home == null || msvcToolset() == null)
				return null;
			var pinned = Path.join([home, ".tools", "ccache", "ccache.exe"]);
			return FileSystem.exists(pinned) ? pinned : null;
		}
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

	/**
	 * What identifies MSVC's compiler and headers: the toolset and Windows SDK versions, the target, and the include path,
	 * which names both. ccache otherwise checks only cl.exe's size and time, and a cached object must not outlive a change
	 * of SDK. Null outside an MSVC environment.
	 */
	public static function msvcToolset():Null<String> {
		var parts:Array<String> = [];
		for (name in ["VCToolsVersion", "WindowsSDKVersion", "VSCMD_ARG_TGT_ARCH", "INCLUDE"]) {
			var value = Sys.getEnv(name);
			parts.push(value == null ? "" : StringTools.trim(value));
		}
		return parts[0] == "" || parts[1] == "" || parts[3] == "" ? null : parts.join("|");
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
	 *
	 * Windows has no base directory. ccache hands the compiler the relative paths it keys by, and MSVC does not open paths
	 * longer than MAX_PATH even where Windows allows them: from a build tree a few levels deep, `..\..\..\` paths into
	 * vendored sources passed 260 characters and the compile failed (C1083). There the cache reuses objects of the same
	 * build tree only, which still covers a tree that is configured again or deleted and built anew. There the compiler
	 * check is the MSVC toolset (`msvcToolset`) rather than cl.exe's size and time.
	 */
	public static function environment(ccache:Null<String>, projectRoot:String, source:String):Map<String, String> {
		var result:Map<String, String> = [];
		if (ccache != null) {
			if (Sys.systemName() == "Windows") {
				var toolset = msvcToolset();
				if (toolset != null)
					result.set("CCACHE_COMPILERCHECK", "string:" + toolset);
			} else
				result.set("CCACHE_BASEDIR", commonDirectory(projectRoot, source));
			result.set("CCACHE_NOHASHDIR", "1");
			result.set("CCACHE_DEPEND", "1");
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
