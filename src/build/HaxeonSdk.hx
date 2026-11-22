package build;

import compiler.core.UsageError;
import haxe.io.Path;
import sys.FileSystem;

/**
 * Where Haxeon's SDK is (docs/design/SDK_LAYOUT.md): what an app's runner and an ahead-of-time build consume, its libraries
 * under `lib/<target>`, `include/`, `src/` and the CMake package `cmake/HaxeonConfig.cmake`. A checkout's native build stages
 * it in `out/sdk`; a release ships it as `sdk/`. Until Haxeon's home is itself the SDK (step 3 of the note's migration), this
 * is the one place that knows the difference.
 */
class HaxeonSdk {
	/** The manifest at an SDK's root. */
	public static inline final MANIFEST = "haxeon-sdk.toml";

	/** The SDK of the Haxeon at `home`; a usage error naming how to make it when there is none. */
	public static function root(home:String):String {
		var sdk = HaxeonRelease.isRelease(home) ? Path.join([home, "sdk"]) : Path.join([home, "out", "sdk"]);
		if (!FileSystem.exists(Path.join([sdk, MANIFEST])))
			throw new UsageError(HaxeonRelease.isRelease(home)
				? 'This Haxeon release has no SDK ($sdk)'
				: 'This Haxeon checkout has no SDK at $sdk: build it with scripts/build-native.sh');
		return sdk;
	}

	/** The directory of the SDK's CMake package, which `find_package(Haxeon)` reads (`Haxeon_DIR`). */
	public static function cmakeDirectory(home:String):String
		return Path.join([root(home), "cmake"]);
}
