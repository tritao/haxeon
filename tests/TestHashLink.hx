import haxe.io.Path;

/**
 * The checkout's HashLink VM, in the bin of Haxeon's SDK, for a test that runs a program it compiled. The test driver and the
 * suite runner export HAXEON_SDK and put the runtime on the library path; scripts/hl, the same VM behind a bash launcher, cannot be
 * started as a process on Windows.
 */
class TestHashLink {
	public static function vm():String
		return Path.join([directory(), "hl"]);

	/** The VM's directory, the SDK's bin. */
	public static function directory():String {
		var sdk = Sys.getEnv("HAXEON_SDK");
		if (sdk == null || sdk == "")
			throw "HAXEON_SDK is not set: run the test through the test driver (scripts/haxeon dev test)";
		return Path.join([sdk, "bin"]);
	}
}
