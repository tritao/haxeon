package build;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * An unpacked release (`haxeon dev package`, docs/reference/RELEASES.md) rather than a checkout: its root holds the marker
 * `haxeon-release.txt`, and the VM, the CLI and the compiler are in `bin`. The `haxeon` launcher finds the root from its own
 * path (native/haxeon_main.c), so a release works from wherever it is unpacked. The marker's lines are `NAME=VALUE`: `version`,
 * `commit` (the checkout's, which names the compiler), `platform` and `compiler-sources`, the digest of the compiler's sources the
 * release was made from (`AotCompiler.sourcesDigest`), which the shipped compiler's stamps must hold: a release ships no sources.
 */
class HaxeonRelease {
	public static inline final MARKER = "haxeon-release.txt";

	/** The directory below a release's root that holds the VM and the programs beside it. */
	public static inline final BIN = "bin";

	/** The marker's field with the digest of the compiler's sources. */
	public static inline final COMPILER_SOURCES = "compiler-sources";

	public static function isRelease(home:String):Bool
		return FileSystem.exists(Path.join([home, MARKER]));

	/** A field of `home`'s marker, or null when `home` is not a release or the marker has no such field. */
	public static function field(home:String, name:String):Null<String> {
		var path = Path.join([home, MARKER]);
		if (!FileSystem.exists(path))
			return null;
		for (line in File.getContent(path).split("\n")) {
			var separator = line.indexOf("=");
			if (separator > 0 && StringTools.trim(line.substr(0, separator)) == name)
				return StringTools.trim(line.substr(separator + 1));
		}
		return null;
	}

	/** The marker's text. */
	public static function marker(version:String, commit:String, platform:String, compilerSources:String):String
		return 'version=$version\ncommit=$commit\nplatform=$platform\n$COMPILER_SOURCES=$compilerSources\n';
}
