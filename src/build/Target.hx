package build;

import build.execution.ProcessRunner;

enum TargetOs {
	Windows;
	MacOS;
	Linux;
	Other(name:String);
}

enum TargetArch {
	X86;
	X64;
	Arm64;
	Other(name:String);
}

enum TargetAbi {
	Msvc;
	Gnu;
	Darwin;
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

	public function toString():String
		return '${osName(os)}-${archName(arch)}-${abiName(abi)}';

	public static function osName(value:TargetOs):String
		return switch value {
			case TargetOs.Windows: "windows";
			case TargetOs.MacOS: "macos";
			case TargetOs.Linux: "linux";
			case TargetOs.Other(name): name.toLowerCase();
		};

	public static function archName(value:TargetArch):String
		return switch value {
			case TargetArch.X86: "x86";
			case TargetArch.X64: "x64";
			case TargetArch.Arm64: "arm64";
			case TargetArch.Other(name): name.toLowerCase();
		};

	public static function abiName(value:TargetAbi):String
		return switch value {
			case TargetAbi.Msvc: "msvc";
			case TargetAbi.Gnu: "gnu";
			case TargetAbi.Darwin: "darwin";
			case TargetAbi.System: "system";
		};

	public function equals(other:Target):Bool
		return osName(os) == osName(other.os) && archName(arch) == archName(other.arch) && abiName(abi) == abiName(other.abi);
}
