package build;

import compiler.core.UsageError;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * Haxeon's SDK (docs/design/SDK_LAYOUT.md), which is Haxeon's home: its VM and programs in `bin/`, libraries under `lib/<target>`,
 * `include/`, `src/`, the CMake package and the scripts native builds include in `cmake/`, and the manifest `haxeon-sdk.toml`,
 * which names the roots the SDK does not hold itself. A checkout's native build stages one in `out/sdk`, whose manifest names the
 * checkout as `source` and the checkout's own stdlib and templates as roots; a release (`haxeon dev package`,
 * docs/DEVELOPMENT.md, Releases) is one, without `source`. A release's manifest also records `commit` (the checkout's, which names
 * the compiler), `platform` and `compiler-sources`, the digest of the compiler's sources it was made from
 * (`AotCompiler.sourcesDigest`), which the shipped compiler's stamps must hold: a release ships no sources.
 *
 * This class is the one place that knows the layout: every path below an SDK, or below the checkout it was built from, is
 * found through it.
 */
class HaxeonSdk {
	/** The manifest at an SDK's root. */
	public static inline final MANIFEST = "haxeon-sdk.toml";

	/** The manifest's key with the digest of the compiler's sources. */
	public static inline final COMPILER_SOURCES = "compiler-sources";

	/** The SDK this process runs from (`HAXEON_SDK`, which the launcher sets from its own path), or null when none is set. */
	public static function current():Null<String> {
		var sdk = Sys.getEnv("HAXEON_SDK");
		return sdk == null
			|| sdk == "" ? null : Path.normalize(FileSystem.exists(sdk) ? FileSystem.fullPath(sdk) : sdk);
	}

	/**
	 * The SDK the native build of the checkout at `checkout` stages for CMake preset `preset` (CMakeLists.txt, HAXEON_SDK_DIR):
	 * `out/sdk` for the preset whose VM the checkout runs (release, windows-msvc on Windows), the default, and
	 * `out/cmake/<preset>/sdk` for any other. It need not be built yet.
	 */
	public static function ofCheckout(checkout:String, ?preset:String):String
		return preset == null || preset == (Sys.systemName() == "Windows" ? "windows-msvc" : "release") ? Path.join([
			checkout,
			"out",
			"sdk"
		]) : Path.join([
			checkout,
			"out",
			"cmake",
			preset,
			"sdk"
		]);

	/** A top-level string of the SDK's manifest (`version`, `source`, a release's `commit`, ...), or null when it has none. */
	public static function field(home:String, name:String):Null<String> {
		var value:Dynamic = Reflect.field(manifest(home), name);
		return Std.isOfType(value, String) ? value : null;
	}

	/** The checkout the SDK was built from (the manifest's `source`), or null for a release. */
	public static function source(home:String):Null<String> {
		var source = field(home, "source");
		return source == null ? null : Path.normalize(source);
	}

	/** The checkout the SDK was built from; a usage error saying that `what` needs one when the SDK is a release. */
	public static function requireSource(home:String, what:String):String {
		var source = source(home);
		if (source == null)
			throw new UsageError('$what needs a checkout of Haxeon; this Haxeon ($home) is a release');
		return source;
	}

	/** Whether the SDK is a release: one built from no checkout. */
	public static function isRelease(home:String):Bool
		return source(home) == null;

	/** The standard library (`stdlib` in the manifest's `[roots]`). */
	public static function stdlib(home:String):String
		return requiredRoot(home, "stdlib");

	/** The project templates `haxeon create` copies (`templates` in `[roots]`). */
	public static function templates(home:String):String
		return requiredRoot(home, "templates");

	/**
	 * The SDK's haxeon registry (`registry` in `[roots]`): the directory of the index the resolver reads for the `haxeon` registry,
	 * a release's unpacked packages or a checkout's generated live index. Null when the SDK has none.
	 */
	public static function registryRoot(home:String):Null<String>
		return root(home, "registry");

	/**
	 * The SDK's CMake directory: its package (`HaxeonConfig.cmake`, which `find_package(Haxeon)` reads as `Haxeon_DIR`) and the
	 * scripts that native packages' builds include or run (`haxeon-native.cmake`, `haxeon-locked.cmake`, ...).
	 */
	public static function cmakeDirectory(home:String):String
		return Path.join([home, "cmake"]);

	/** The shader driver and Haxe generator, as shipped by the SDK or read live in a checkout. */
	public static function shaderTools(home:String):{build:String, driver:String, generator:String} {
		var checkout = source(home);
		var root = Path.join([home, "tools", "shaders"]);
		return checkout == null ? {
			build: Path.join([root, "build.py"]),
			driver: Path.join([root, "shaders.py"]),
			generator: Path.join([root, "generate-shader-haxe.py"])
		} : {
			build: Path.join([checkout, "tools", "shaders", "build.py"]),
			driver: Path.join([checkout, "vendor", "nativekit", "modules", "gpu", "tools", "shaders.py"]),
			generator: Path.join([checkout, "packages", "gpu", "tools", "generate-shader-haxe.py"])
		};
	}

	/** The runtime's headers (`hl.h`, ...), which native code built for the VM compiles against. */
	public static function includeDirectory(home:String):String
		return Path.join([home, "include"]);

	/** A release's manifest: its own roots, and what the release was made from. */
	public static function releaseManifest(version:String, commit:String, platform:String,
			compilerSources:String):String
		return '# Haxeon\'s SDK manifest (docs/design/SDK_LAYOUT.md), of a release.\nversion = "$version"\ncommit = "$commit"\n'
			+ 'platform = "$platform"\n$COMPILER_SOURCES = "$compilerSources"\n\n[roots]\nstdlib = "stdlib"\ntemplates = "templates"\nregistry = "registry"\n';

	static function requiredRoot(home:String, name:String):String {
		var path = root(home, name);
		if (path == null)
			throw new UsageError('The Haxeon SDK at $home names no $name root in its $MANIFEST');
		return path;
	}

	/** A root of `[roots]`, relative to the SDK unless absolute. */
	static function root(home:String, name:String):Null<String> {
		var roots:Dynamic = Reflect.field(manifest(home), "roots"),
			path:Dynamic = roots == null ? null : Reflect.field(roots, name);
		if (!Std.isOfType(path, String))
			return null;
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([home, path]));
	}

	/** The manifest, parsed; a usage error naming how to make the SDK when there is none. */
	static function manifest(home:String):Dynamic {
		var path = Path.join([home, MANIFEST]);
		if (!FileSystem.exists(path))
			throw new UsageError('There is no Haxeon SDK at $home (no $MANIFEST); in a checkout, build it with scripts/build-native.sh');
		return toml.TomlParser.parse(File.getContent(path));
	}
}
