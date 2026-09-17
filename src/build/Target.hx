package build;

import build.execution.ProcessRunner;

enum TargetOs {
	Windows;
	MacOS;
	Linux;
	Android;
	Wasm;
	Other(name:String);
}

enum TargetArch {
	X86;
	X64;
	Arm64;
	Wasm32;
	Other(name:String);
}

enum TargetAbi {
	Msvc;
	Gnu;
	Darwin;
	Android;
	Wasm;
	System;
}

/** The host target known to this build invocation. */
class Target {
	static var cachedHostTarget:Null<Target>;

	public final os:TargetOs;
	public final arch:TargetArch;
	public final abi:TargetAbi;

	public function new(os:TargetOs, arch:TargetArch, abi:TargetAbi) {
		this.os = os;
		this.arch = arch;
		this.abi = abi;
	}

	public static function detectHost():Target {
		if (cachedHostTarget != null)
			return cachedHostTarget;
		var system = Sys.systemName();
		var os = switch system {
			case "Windows": TargetOs.Windows;
			case "Mac": TargetOs.MacOS;
			case "Linux": TargetOs.Linux;
			case _: TargetOs.Other(system);
		};
		var archName = Sys.getEnv("PROCESSOR_ARCHITECTURE");
		if (archName == null || archName == "")
			archName = Sys.getEnv("HOSTTYPE");
		if (archName == null || archName == "")
			archName = Sys.getEnv("MACHTYPE");
		if ((archName == null || archName == "") && system != "Windows") {
			var machine = ProcessRunner.capture("uname", ["-m"]);
			if (machine.status == 0)
				archName = StringTools.trim(machine.output);
		}
		if (archName == null || archName == "")
			archName = "unknown";
		var arch = switch archName.toLowerCase() {
			case "x86", "i386", "i486", "i586", "i686": TargetArch.X86;
			case "x86_64", "amd64", "x64": TargetArch.X64;
			case "aarch64", "arm64": TargetArch.Arm64;
			case _: TargetArch.Other(archName);
		};
		var abi = switch os {
			case TargetOs.Windows: TargetAbi.Msvc;
			case TargetOs.MacOS: TargetAbi.Darwin;
			case TargetOs.Linux: TargetAbi.Gnu;
			case _: TargetAbi.System;
		};
		cachedHostTarget = new Target(os, arch, abi);
		return cachedHostTarget;
	}

	/** Parse the stable target names accepted by manifests and the CLI. */
	public static function parse(value:String):Target {
		var normalized = StringTools.trim(value).toLowerCase();
		if (normalized == "host")
			return detectHost();
		if (normalized == "wasm32" || normalized == "wasm32-wasi")
			return new Target(TargetOs.Wasm, TargetArch.Wasm32, TargetAbi.Wasm);
		var parts = normalized.split("-");
		if (parts.length == 0 || parts[0] == "")
			throw 'Target "$value" is empty';
		var os = switch parts[0] {
			case "windows", "win": TargetOs.Windows;
			case "macos", "darwin", "mac": TargetOs.MacOS;
			case "linux": TargetOs.Linux;
			case "android": TargetOs.Android;
			case _: throw 'Unknown target operating system in "$value"';
		};
		var archText = parts.length > 1 ? parts[1] : (os == TargetOs.Android ? "aarch64" : "x86_64"),
			arch = switch archText {
				case "x86", "i386", "i486", "i586", "i686": TargetArch.X86;
				case "x86_64", "amd64", "x64": TargetArch.X64;
				case "aarch64", "arm64": TargetArch.Arm64;
				case "wasm32": TargetArch.Wasm32;
				case _: throw 'Unknown target architecture in "$value"';
			};
		var abi = if (parts.length > 2) switch parts[2] {
			case "msvc": TargetAbi.Msvc;
			case "gnu", "mingw": TargetAbi.Gnu;
			case "darwin": TargetAbi.Darwin;
			case "android": TargetAbi.Android;
			case "wasm", "wasi": TargetAbi.Wasm;
			case "system": TargetAbi.System;
			case _: throw 'Unknown target ABI in "$value"';
		} else switch os {
			case TargetOs.Windows: TargetAbi.Msvc;
			case TargetOs.MacOS: TargetAbi.Darwin;
			case TargetOs.Linux: TargetAbi.Gnu;
			case TargetOs.Android: TargetAbi.Android;
			case TargetOs.Wasm: TargetAbi.Wasm;
			case TargetOs.Other(_): TargetAbi.System;
		};
		if (os == TargetOs.Android && abi != TargetAbi.Android)
			throw 'Android target "$value" must use the android ABI';
		if (os != TargetOs.Android && abi == TargetAbi.Android)
			throw 'Only Android targets may use the android ABI';
		if (os == TargetOs.Wasm || arch == TargetArch.Wasm32)
			throw 'Use "wasm32" for Wasm targets';
		return new Target(os, arch, abi);
	}

	public function toString():String
		return switch os {
			case TargetOs.Wasm: "wasm32";
			case TargetOs.Android: '${osName(os)}-${archName(arch)}';
			case TargetOs.MacOS: '${osName(os)}-${archName(arch)}';
			case _: '${osName(os)}-${archName(arch)}-${abiName(abi)}';
		};

	public static function osName(value:TargetOs):String
		return switch value {
			case TargetOs.Windows: "windows";
			case TargetOs.MacOS: "macos";
			case TargetOs.Linux: "linux";
			case TargetOs.Android: "android";
			case TargetOs.Wasm: "wasm";
			case TargetOs.Other(name): name.toLowerCase();
		};

	public static function archName(value:TargetArch):String
		return switch value {
			case TargetArch.X86: "x86";
			case TargetArch.X64: "x86_64";
			case TargetArch.Arm64: "arm64";
			case TargetArch.Wasm32: "wasm32";
			case TargetArch.Other(name): name.toLowerCase();
		};

	public static function abiName(value:TargetAbi):String
		return switch value {
			case TargetAbi.Msvc: "msvc";
			case TargetAbi.Gnu: "gnu";
			case TargetAbi.Darwin: "darwin";
			case TargetAbi.Android: "android";
			case TargetAbi.Wasm: "wasm";
			case TargetAbi.System: "system";
		};

	public function equals(other:Target):Bool
		return osName(os) == osName(other.os) && archName(arch) == archName(other.arch) && abiName(abi) == abiName(other.abi);

	public function isWasm():Bool
		return os == TargetOs.Wasm || arch == TargetArch.Wasm32 || abi == TargetAbi.Wasm;

	public function isAndroid():Bool
		return os == TargetOs.Android || abi == TargetAbi.Android;

	public function isNative():Bool
		return !isWasm();
}
