package build;

import haxe.io.Path;

/** The VM's directory: the bin of Haxeon's SDK (docs/design/SDK_LAYOUT.md). */
class HashLinkPath {
	public static function directory(home:String):String
		return Path.join([home, "bin"]);

	/**
	 * The SDK's static libraries for this machine (`lib/<target>`, the target as `Target` spells it, which the native build's
	 * `haxeon-sdk` names them by): the VM's archive and the profiler's function hooks.
	 */
	public static function libraryDirectory(home:String):String
		return Path.join([home, "lib", Target.detectHost().toString()]);

	public static function executable(home:String, name:String = "hl"):String
		return Path.join([directory(home), name + (Sys.systemName() == "Windows" ? ".exe" : "")]);

	/**
	 * The directories the VM loads native libraries from by name: the VM's own and, in a checkout, `out/`, where the native build
	 * leaves the libraries tests load.
	 */
	public static function libraryPath(home:String):Array<String> {
		var source = HaxeonSdk.source(home);
		return source == null ? [directory(home)] : [Path.join([source, "out"]), directory(home)];
	}
}
