package build;

import haxe.io.Path;
import sys.FileSystem;
import build.Target.TargetAbi;
import build.Target.TargetArch;

enum abstract BuildProfile(String) from String to String {
	var Debug = "debug";
	var Release = "release";
}

class ToolchainInfo {
	public final cCompiler:String;
	public final cxxCompiler:String;
	public final linker:String;
	public final archiver:String;
	public final targetTriple:Null<String>;
	public final sysroot:Null<String>;
	public final compileFlags:Array<String>;
	public final linkFlags:Array<String>;
	public final objectSuffix:String;
	public final staticLibrarySuffix:String;
	public final sharedLibrarySuffix:String;

	public function new(cCompiler:String, cxxCompiler:String, archiver:String, objectSuffix:String, staticLibrarySuffix:String, sharedLibrarySuffix:String,
		?linker:String, ?targetTriple:String, ?sysroot:String, ?compileFlags:Array<String>, ?linkFlags:Array<String>) {
		this.cCompiler = cCompiler;
		this.cxxCompiler = cxxCompiler;
		this.linker = linker == null ? cxxCompiler : linker;
		this.archiver = archiver;
		this.targetTriple = targetTriple;
		this.sysroot = sysroot;
		this.compileFlags = compileFlags == null ? [] : compileFlags.copy();
		this.linkFlags = linkFlags == null ? [] : linkFlags.copy();
		this.objectSuffix = objectSuffix;
		this.staticLibrarySuffix = staticLibrarySuffix;
		this.sharedLibrarySuffix = sharedLibrarySuffix;
	}

	public static function detect(target:Target):ToolchainInfo {
		return switch target.os {
			case Windows:
				if (target.abi == TargetAbi.Gnu)
					new ToolchainInfo("x86_64-w64-mingw32-gcc", "x86_64-w64-mingw32-g++", "x86_64-w64-mingw32-ar", ".o", ".a", ".dll",
						"x86_64-w64-mingw32-g++", "x86_64-w64-mingw32");
				else
					new ToolchainInfo("cl", "cl", "lib", ".obj", ".lib", ".dll", "cl");
			case MacOS:
				var flags = target.arch == TargetArch.Arm64 ? ["-arch", "arm64"] : target.arch == TargetArch.X86 ? ["-arch", "i386"] : [];
				new ToolchainInfo("clang", "clang++", "ar", ".o", ".a", ".dylib", "clang++", null, null, flags, flags);
			case Linux:
				if (target.arch == TargetArch.Arm64)
					new ToolchainInfo("aarch64-linux-gnu-gcc", "aarch64-linux-gnu-g++", "aarch64-linux-gnu-ar", ".o", ".a", ".so",
						"aarch64-linux-gnu-g++", "aarch64-linux-gnu");
				else
					new ToolchainInfo("cc", "c++", "ar", ".o", ".a", ".so");
			case Android:
				androidToolchain(target);
			case Wasm:
				new ToolchainInfo("clang", "clang++", "llvm-ar", ".o", ".a", ".wasm", "wasm-ld", "wasm32-wasi", null,
					["--target=wasm32-wasi"], ["--target=wasm32-wasi"]);
			case Other(_):
				new ToolchainInfo("cc", "c++", "ar", ".o", ".a", ".so");
		};
	}

	static function androidToolchain(target:Target):ToolchainInfo {
		var ndk = Sys.getEnv("ANDROID_NDK_HOME");
		if (ndk == null || ndk == "")
			ndk = Sys.getEnv("ANDROID_NDK_ROOT");
		var hostTag = switch Sys.systemName() {
			case "Windows": "windows-x86_64";
			case "Mac": "darwin-arm64";
			case _: "linux-x86_64";
		};
		var triple = switch target.arch {
			case TargetArch.Arm64: "aarch64-linux-android21";
			case TargetArch.X64: "x86_64-linux-android21";
			case TargetArch.X86: "i686-linux-android21";
			case _: throw "Android requires an x86, x86_64, or arm64 architecture";
		};
		var bin = ndk == null || ndk == "" ? "" : Path.join([ndk, "toolchains", "llvm", "prebuilt", hostTag, "bin"]),
			compiler = bin == "" ? "clang" : Path.join([bin, "clang"]),
			cxx = bin == "" ? "clang++" : Path.join([bin, "clang++"]),
			archiver = bin == "" ? "llvm-ar" : Path.join([bin, "llvm-ar"]),
			flags = ["--target=" + triple];
		return new ToolchainInfo(compiler, cxx, archiver, ".o", ".a", ".so", cxx, triple, ndk, flags, flags);
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
