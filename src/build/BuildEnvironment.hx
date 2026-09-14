package build;

import haxe.io.Path;
import sys.FileSystem;

enum abstract BuildProfile(String) from String to String {
	var Debug = "debug";
	var Release = "release";
}

class ToolchainInfo {
	public final cCompiler:String;
	public final cxxCompiler:String;
	public final archiver:String;
	public final objectSuffix:String;
	public final staticLibrarySuffix:String;
	public final sharedLibrarySuffix:String;

	public function new(cCompiler:String, cxxCompiler:String, archiver:String, objectSuffix:String, staticLibrarySuffix:String, sharedLibrarySuffix:String) {
		this.cCompiler = cCompiler;
		this.cxxCompiler = cxxCompiler;
		this.archiver = archiver;
		this.objectSuffix = objectSuffix;
		this.staticLibrarySuffix = staticLibrarySuffix;
		this.sharedLibrarySuffix = sharedLibrarySuffix;
	}

	public static function detect(target:Target):ToolchainInfo {
		return switch target.os {
			case Windows:
				new ToolchainInfo("cl", "cl", "lib", ".obj", ".lib", ".dll");
			case MacOS:
				new ToolchainInfo("clang", "clang++", "ar", ".o", ".a", ".dylib");
			case Linux:
				new ToolchainInfo("cc", "c++", "ar", ".o", ".a", ".so");
			case Other(_):
				new ToolchainInfo("cc", "c++", "ar", ".o", ".a", ".so");
		};
	}
}

/** Immutable facts captured once at the boundary of a build. */
class BuildEnvironment {
	public final projectRoot:String;
	public final buildRoot:String;
	public final target:Target;
	public final profile:BuildProfile;
	public final toolchain:ToolchainInfo;

	public function new(projectRoot:String, buildRoot:String, profile:BuildProfile = BuildProfile.Debug, ?target:Target, ?toolchain:ToolchainInfo) {
		var canonicalRoot = FileSystem.fullPath(projectRoot);
		this.projectRoot = Path.normalize(canonicalRoot);
		this.buildRoot = Path.normalize(Path.isAbsolute(buildRoot) ? buildRoot : Path.join([canonicalRoot, buildRoot]));
		this.target = target == null ? Target.detectHost() : target;
		this.profile = profile;
		this.toolchain = toolchain == null ? ToolchainInfo.detect(this.target) : toolchain;
	}

	public static function fromCurrentDirectory(?buildDirectory:String = "out", profile:BuildProfile = BuildProfile.Debug):BuildEnvironment {
		var root = FileSystem.fullPath(Sys.getCwd());
		return new BuildEnvironment(root, Path.join([root, buildDirectory]), profile);
	}
}
