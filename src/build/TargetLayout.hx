package build;

import haxe.io.Path;

/** Converts logical package outputs to paths below one build root. */
class TargetLayout {
	final environment:BuildEnvironment;

	public function new(environment:BuildEnvironment)
		this.environment = environment;

	public function packageRoot(packageName:String):String
		return Path.join([environment.buildRoot, "host", "native", packageName]);

	public function hashLinkModulePath(packageName:String):String
		return Path.join([
			environment.buildRoot,
			"host",
			packageName == "" ? "main.hl" : packageName + ".hl"
		]);

	public function hashLinkPatchPath(packageName:String):String
		return Path.join([environment.buildRoot, "host", packageName + ".hlp"]);

	public function wasmModulePath(packageName:String):String
		return Path.join([
			environment.buildRoot,
			"wasm32",
			packageName == "" ? "main.wasm" : packageName + ".wasm"
		]);

	public function objectPath(packageName:String, source:String):String {
		var relative = StringTools.startsWith(source, "native/") ? source.substr("native/".length) : source;
		return Path.join([
			packageRoot(packageName),
			Path.withoutExtension(relative) + environment.toolchain.objectSuffix
		]);
	}

	public function nativeStaticLibraryPath(packageName:String, libraryName:String):String
		return Path.join([
			packageRoot(packageName),
			"lib" + libraryName + environment.toolchain.staticLibrarySuffix
		]);

	public function nativeSharedLibraryPath(packageName:String, libraryName:String):String
		return Path.join([
			packageRoot(packageName),
			"lib" + libraryName + environment.toolchain.sharedLibrarySuffix
		]);

	public function haxeonNativeLibraryPath(packageName:String):String
		return Path.join([packageRoot(packageName), packageName + ".hdll"]);
}
