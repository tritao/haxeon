package build;

import haxe.io.Path;
import build.Target.TargetArch;

/** Converts logical package outputs to paths below one build root. */
class TargetLayout {
	final environment:BuildEnvironment;

	public function new(environment:BuildEnvironment)
		this.environment = environment;

	public function packageRoot(packageName:String):String
		return Path.join([environment.buildRoot, targetDirectory(), "native", packageName]);

	public function hashLinkModulePath(packageName:String):String
		return Path.join([
			environment.buildRoot,
			targetDirectory(),
			packageName == "" ? "main.hl" : packageName + ".hl"
		]);

	public function hashLinkPatchPath(packageName:String):String
		return Path.join([environment.buildRoot, targetDirectory(), packageName + ".hlp"]);

	public function wasmModulePath(packageName:String):String
		return Path.join([
			environment.buildRoot,
			targetDirectory(),
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

	public function haxeonNativeLibraryPath(packageName:String):String {
		if (environment.target.isAndroid())
			return Path.join([
				environment.buildRoot,
				targetDirectory(),
				"jniLibs",
				androidAbi(),
				"lib" + packageName + ".so"
			]);
		return Path.join([packageRoot(packageName), packageName + ".hdll"]);
	}

	public function ffiRoot(packageName:String, name:String):String
		return Path.join([packageRoot(packageName), "ffi", safeFfiName(name)]);

	public function ffiInterfacePath(packageName:String, name:String):String
		return Path.join([ffiRoot(packageName, name), safeFfiName(name) + ".hxi"]);

	public function ffiProjectionPath(packageName:String, name:String):String
		return Path.join([ffiRoot(packageName, name), "projection"]);

	public function ffiProjectionManifestPath(packageName:String, name:String):String
		return Path.join([ffiRoot(packageName, name), "projection.sources"]);

	public function ffiThunkSourcePath(packageName:String, name:String):String
		return Path.join([ffiRoot(packageName, name), safeFfiName(name) + "-thunks.cpp"]);

	public function ffiNativeLibraryPath(packageName:String, name:String):String
		return Path.join([
			packageRoot(packageName),
			"lib" + safeFfiName(name) + environment.toolchain.sharedLibrarySuffix
		]);

	public function targetDirectory():String {
		if (environment.target.equals(Target.detectHost()))
			return "host";
		return environment.target.toString();
	}

	public function androidAbi():String {
		if (!environment.target.isAndroid())
			throw "JNI ABI is only defined for Android targets";
		return switch environment.target.arch {
			case TargetArch.Arm64: "arm64-v8a";
			case TargetArch.X64: "x86_64";
			case TargetArch.X86: "x86";
			case _: throw 'Android does not support target architecture ${Target.archName(environment.target.arch)}';
		};
	}

	static function safeFfiName(name:String):String
		return StringTools.replace(StringTools.replace(name, "/", "_"), "\\", "_");
}
