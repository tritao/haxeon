package build;

import compiler.core.UsageError;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * Haxeon's SDK (docs/design/SDK_LAYOUT.md): its VM and programs in `bin/`, libraries under `lib/<target>`, `include/`, `src/`, the
 * CMake package `cmake/HaxeonConfig.cmake`, and the manifest `haxeon-sdk.toml`. A checkout's native build stages one in
 * `out/sdk`, whose manifest names the checkout as `source`; a release (`haxeon dev package`, docs/reference/RELEASES.md) is
 * one, without `source`. `home` (`HAXEON_HOME`) is the checkout when there is one and the SDK otherwise, so a release's manifest
 * is at `home`. A release's manifest also records `commit` (the checkout's, which names the compiler), `platform` and
 * `compiler-sources`, the digest of the compiler's sources it was made from (`AotCompiler.sourcesDigest`), which the shipped
 * compiler's stamps must hold: a release ships no sources.
 */
class HaxeonSdk {
	/** The manifest at an SDK's root. */
	public static inline final MANIFEST = "haxeon-sdk.toml";

	/** The manifest's key with the digest of the compiler's sources. */
	public static inline final COMPILER_SOURCES = "compiler-sources";

	/** Whether the Haxeon at `home` is a release: an SDK with no checkout. */
	public static function isRelease(home:String):Bool
		return FileSystem.exists(Path.join([home, MANIFEST]));

	/** The SDK of the Haxeon at `home`; a usage error naming how to make it when there is none. */
	public static function root(home:String):String {
		var sdk = isRelease(home) ? home : Path.join([home, "out", "sdk"]);
		if (!FileSystem.exists(Path.join([sdk, MANIFEST])))
			throw new UsageError('This Haxeon checkout has no SDK at $sdk: build it with scripts/build-native.sh');
		return sdk;
	}

	/** The directory of the SDK's CMake package, which `find_package(Haxeon)` reads (`Haxeon_DIR`). */
	public static function cmakeDirectory(home:String):String
		return Path.join([root(home), "cmake"]);

	/** A top-level key of a release's manifest, or null when `home` is not a release or the manifest has no such key. */
	public static function releaseField(home:String, name:String):Null<String> {
		var path = Path.join([home, MANIFEST]);
		if (!FileSystem.exists(path))
			return null;
		for (line in File.getContent(path).split("\n")) {
			if (StringTools.startsWith(line, "["))
				break;
			var separator = line.indexOf("=");
			if (separator > 0 && StringTools.trim(line.substr(0, separator)) == name) {
				var value = StringTools.trim(line.substr(separator + 1));
				return StringTools.startsWith(value, '"') && StringTools.endsWith(value, '"') ? value.substr(1, value.length - 2) : value;
			}
		}
		return null;
	}

	/** A release's manifest: its own roots, and what the release was made from. */
	public static function releaseManifest(version:String, commit:String, platform:String, compilerSources:String):String
		return '# Haxeon\'s SDK manifest (docs/design/SDK_LAYOUT.md), of a release.\nversion = "$version"\ncommit = "$commit"\n'
			+ 'platform = "$platform"\n$COMPILER_SOURCES = "$compilerSources"\n\n[roots]\nstdlib = "stdlib"\ntemplates = "templates"\n';
}
