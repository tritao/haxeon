package build.native;

import build.BuildEnvironment;
import build.TargetLayout;
import haxe.crypto.Sha256;
import haxe.io.Path;
import project.ResolvedPackage;
import sys.FileSystem;

/**
 * Where CMake packages build when a project build shares them. Every project that uses a native package reaches the
 * same tree, so an application and the test projects that depend on it configure and compile the package once.
 *
 * A tree is named by what decides its contents: the package, the real path of the CMake source directory (so
 * checkouts and worktrees that hold different sources never share, and ones that reach the same source through
 * junctions or symbolic links do), the CMake target, the build target and the profile. A different toolchain or
 * generator is a different `cmake*` directory inside it. CMake and Ninja rebuild what a source change touched, so
 * sharing a tree never serves stale code. Each configure, build and publish step of a tree runs under its cross-process lock (`cmake/haxeon-locked.cmake`).
 *
 * Packages publish their runtime libraries into the project's own `host/native/<package>` directory afterwards, so
 * everything that loads libraries from a project's build directory keeps working.
 */
class NativeCache {
	/** `file(REAL_PATH)` needs CMake 3.19. */
	static final minimumCMake = [3, 19];

	static var cmakeUsable:Null<Bool> = null;
	static var scriptHome:Null<String> = null;
	static final realPaths = new Map<String, String>();

	/**
	 * The cache directory, or null when projects build their own trees. `HAXEON_NATIVE_CACHE` names another directory,
	 * `off` disables the cache. The instrumented flavor keeps its own trees, which publish debug databases as well.
	 */
	public static function root(home:String, environment:BuildEnvironment):Null<String> {
		var configured = Sys.getEnv("HAXEON_NATIVE_CACHE");
		if (environment.instrument != null || configured == "off" || configured == "0" || !cmakeAtLeast())
			return null;
		scriptHome = home;
		return canonical(configured != null && configured != "" ? configured : Path.join([home, "out", "native-cache"]));
	}

	/**
	 * One spelling for a path: real (junctions and links followed), forward slashes, and on Windows a lower-case drive
	 * letter. Callers that reach the same directory by different routes, such as a shell and a script, get the same
	 * answer, so keys and CMake arguments stay the same and nothing rebuilds.
	 */
	public static function canonical(path:String):String {
		var exists = FileSystem.exists(path), normalized = Path.normalize(exists ? FileSystem.fullPath(path) : path);
		var known = realPaths.get(normalized);
		if (known != null)
			return known;
		var real = normalized;
		if (exists && scriptHome != null) {
			var output = HostCommand.text("cmake", ["-DP=" + normalized, "-P", Path.join([scriptHome, "cmake", "haxeon-real-path.cmake"])]);
			if (output != null && output != "")
				real = Path.normalize(output);
		}
		if (Sys.systemName() == "Windows" && real.length > 1 && real.charAt(1) == ":")
			real = real.charAt(0).toLowerCase() + real.substr(1);
		realPaths.set(normalized, real);
		return real;
	}

	/** The tree of a package's CMake project: `cmake*` holds the build and `out` the libraries it produces. */
	public static function treeRoot(root:String, layout:TargetLayout, environment:BuildEnvironment, resolvedPackage:ResolvedPackage, source:String,
			target:String):String {
		// What decides a tree's configuration: the source, the target and profile, the haxeon home (CMAKE_PROJECT_INCLUDE and
		// the pinned tools come from it) and the compilers. The configure arguments are the same for every project that
		// reaches a package (NativeKit modules are chosen by the packages' own CMakeLists, not by arguments), so nothing else
		// of a project belongs here.
		var fullSource = canonical(source), home = scriptHome == null ? "" : canonical(scriptHome),
			compilers = [for (name in ["CC", "CXX", "VCToolsVersion", "VisualStudioVersion"]) name + "=" + Std.string(Sys.getEnv(name))].join(",");
		var identity = [fullSource, target, environment.target.toString(), Std.string(environment.profile), home, compilers].join("\n");
		// Case-insensitive file systems (Windows, macOS) reach one directory by several spellings.
		if (Sys.systemName() == "Windows" || Sys.systemName() == "Mac")
			identity = identity.toLowerCase();
		var key = Sha256.encode(identity).substr(0, 10),
			name = new EReg("[^A-Za-z0-9_.]+", "g").replace(resolvedPackage.name, "-");
		return Path.join([root, layout.targetDirectory(), name + "-" + key]);
	}

	static function cmakeAtLeast():Bool {
		if (cmakeUsable == null) {
			var version = HostCommand.text("cmake", ["--version"]), usable = false;
			if (version != null) {
				var pattern = new EReg("version ([0-9]+)[.]([0-9]+)", "");
				if (pattern.match(version)) {
					var major = Std.parseInt(pattern.matched(1)), minor = Std.parseInt(pattern.matched(2));
					usable = major > minimumCMake[0] || (major == minimumCMake[0] && minor >= minimumCMake[1]);
				}
			}
			cmakeUsable = usable;
		}
		return cmakeUsable;
	}
}
