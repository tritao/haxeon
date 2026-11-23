package build;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * A release (`haxeon dev package`, docs/reference/RELEASES.md) rather than a checkout. A release's root is Haxeon's SDK
 * (docs/design/SDK_LAYOUT.md) and `HAXEON_HOME`, so its manifest `haxeon-sdk.toml` is at `home`; a checkout's home is the
 * checkout, whose SDK is in `out/sdk`. The `haxeon` launcher finds the SDK from its own path (native/haxeon_main.c), so a
 * release works from wherever it is unpacked. The manifest's top-level keys a release adds: `commit` (the checkout's, which
 * names the compiler), `platform` and `compiler-sources`, the digest of the compiler's sources the release was made from
 * (`AotCompiler.sourcesDigest`), which the shipped compiler's stamps must hold: a release ships no sources.
 */
class HaxeonRelease {
	/** The directory below a release's root that holds the VM and the programs beside it. */
	public static inline final BIN = "bin";

	/** The manifest's key with the digest of the compiler's sources. */
	public static inline final COMPILER_SOURCES = "compiler-sources";

	public static function isRelease(home:String):Bool
		return FileSystem.exists(Path.join([home, HaxeonSdk.MANIFEST]));

	/** A top-level key of a release's manifest, or null when `home` is not a release or the manifest has no such key. */
	public static function field(home:String, name:String):Null<String> {
		var path = Path.join([home, HaxeonSdk.MANIFEST]);
		if (!FileSystem.exists(path))
			return null;
		for (line in File.getContent(path).split("\n")) {
			if (StringTools.startsWith(line, "["))
				break;
			var separator = line.indexOf("=");
			if (separator > 0 && StringTools.trim(line.substr(0, separator)) == name) {
				var value = StringTools.trim(line.substr(separator + 1));
				return StringTools.startsWith(value, '"')
					&& StringTools.endsWith(value, '"') ? value.substr(1, value.length - 2) : value;
			}
		}
		return null;
	}

	/** A release's manifest: its SDK's, with its own roots, and what the release was made from. */
	public static function manifest(version:String, commit:String, platform:String, compilerSources:String):String
		return '# Haxeon\'s SDK manifest (docs/design/SDK_LAYOUT.md), of a release.\nversion = "$version"\ncommit = "$commit"\n'
			+ 'platform = "$platform"\n$COMPILER_SOURCES = "$compilerSources"\n\n[roots]\nstdlib = "stdlib"\ntemplates = "templates"\n';
}
