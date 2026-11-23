package build;

import compiler.core.UsageError;
import haxe.io.Path;
import sys.FileSystem;

/**
 * Where Haxeon's SDK is (docs/design/SDK_LAYOUT.md): what an app's runner and an ahead-of-time build consume, its VM and
 * programs in `bin/`, libraries under `lib/<target>`, `include/`, `src/` and the CMake package `cmake/HaxeonConfig.cmake`. A
 * release's root is its SDK; a checkout's native build stages one in `out/sdk`, whose manifest names the checkout as `source`.
 * `home` (`HAXEON_HOME`) is the checkout when there is one and the SDK otherwise.
 */
class HaxeonSdk {
	/** The manifest at an SDK's root. */
	public static inline final MANIFEST = "haxeon-sdk.toml";

	/** The SDK of the Haxeon at `home`; a usage error naming how to make it when there is none. */
	public static function root(home:String):String {
		var sdk = HaxeonRelease.isRelease(home) ? home : Path.join([home, "out", "sdk"]);
		if (!FileSystem.exists(Path.join([sdk, MANIFEST])))
			throw new UsageError('This Haxeon checkout has no SDK at $sdk: build it with scripts/build-native.sh');
		return sdk;
	}

	/** The directory of the SDK's CMake package, which `find_package(Haxeon)` reads (`Haxeon_DIR`). */
	public static function cmakeDirectory(home:String):String
		return Path.join([root(home), "cmake"]);
}
