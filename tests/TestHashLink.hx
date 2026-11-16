import haxe.io.Path;

/**
 * The checkout's HashLink VM, for a test that runs a program it compiled. The test driver and the suite runner export
 * HAXEON_HASHLINK_DIR and put the runtime on the library path; scripts/hl, the same VM behind a bash launcher, cannot be
 * started as a process on Windows.
 */
class TestHashLink {
	public static function vm():String {
		var directory = Sys.getEnv("HAXEON_HASHLINK_DIR");
		if (directory == null || directory == "")
			throw "HAXEON_HASHLINK_DIR is not set: run the test through the test driver (scripts/haxeon dev test)";
		return Path.join([directory, "hl"]);
	}
}
