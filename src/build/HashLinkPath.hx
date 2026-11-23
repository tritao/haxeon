package build;

import haxe.io.Path;

/** The VM's directory: the bin of Haxeon's SDK, a release's own or a checkout's out/sdk (docs/design/SDK_LAYOUT.md). */
class HashLinkPath {
	public static function directory(home:String):String
		return HaxeonSdk.isRelease(home) ? Path.join([home, "bin"]) : Path.join([home, "out", "sdk", "bin"]);

	/**
	 * Where the build of CMake preset `preset` publishes the VM: the checkout's SDK for the preset whose VM the checkout runs
	 * (release, windows-msvc on Windows), the SDK the build stages in its own directory for any other (CMakeLists.txt,
	 * HAXEON_SDK_DIR).
	 */
	public static function forPreset(home:String, preset:String):String
		return preset == (Sys.systemName() == "Windows" ? "windows-msvc" : "release") ? directory(home) : Path.join([
			home,
			"out",
			"cmake",
			preset,
			"sdk",
			"bin"
		]);

	/**
	 * The SDK's static libraries for this machine (`lib/<target>`, the target as `Target` spells it, which the native build's
	 * `haxeon-sdk` names them by): the VM's archive and the profiler's function hooks.
	 */
	public static function libraryDirectory(home:String):String
		return Path.join([Path.directory(directory(home)), "lib", Target.detectHost().toString()]);

	public static function executable(home:String, name:String = "hl"):String
		return Path.join([directory(home), name + (Sys.systemName() == "Windows" ? ".exe" : "")]);
}
