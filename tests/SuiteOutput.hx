/**
 * Where a test main writes the files a script reads back: HAXEON_SUITE_OUT, the directory the test runner gives each suite, else out/
 * when the main runs by hand. The driver and the Wasm lane run some of the same mains at the same time; each writes its own directory.
 */
class SuiteOutput {
	public static function path(name:String):String {
		var directory = Sys.getEnv("HAXEON_SUITE_OUT");
		return (directory == null || directory == "" ? "out" : directory) + "/" + name;
	}
}
