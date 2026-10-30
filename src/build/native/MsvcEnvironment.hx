package build.native;

import build.Target.TargetArch;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;

/**
 * The MSVC developer environment (`INCLUDE`, `LIB`, `cl` and Ninja on `PATH`) that Ninja builds of CMake packages need on
 * Windows. The Visual Studio generator finds MSVC by itself; Ninja runs `cl` directly.
 *
 * A build started from a developer prompt for the target keeps that prompt's environment. Otherwise, including from a
 * prompt for another architecture (the default Developer Command Prompt targets x86), the newest Visual Studio with the
 * target's C++ tools is found with `vswhere` and its `vcvarsall.bat` is run; the variables it adds or changes are copied
 * into this process, so every CMake and Ninja run after it inherits the same toolchain.
 */
class MsvcEnvironment {
	/** Targets whose environment could not be loaded, so that a build does not search for Visual Studio again for each package. */
	static final unavailable = new Map<String, Bool>();

	/** Whether MSVC's environment for `target` is in place, loading it when needed; false when Visual Studio cannot provide it. */
	public static function ensure(target:TargetArch):Bool {
		var tools = toolset(hostArch(), target);
		if (tools == null)
			return false;
		if (active(tools))
			return true;
		if (unavailable.exists(tools.argument))
			return false;
		if (load(tools))
			return true;
		unavailable.set(tools.argument, true);
		return false;
	}

	/**
	 * The names vcvarsall and VSCMD use for a host and target, the vcvarsall argument for them (`x64`, or `x64_arm64` for a
	 * cross build), and the Visual Studio component with the target's compilers. Null for an architecture MSVC does not build.
	 */
	static function toolset(host:TargetArch, target:TargetArch):Null<MsvcToolset> {
		var hostName = archName(host), targetName = archName(target);
		if (hostName == null || targetName == null)
			return null;
		return {
			hostName: hostName,
			targetName: targetName,
			argument: hostName == targetName ? targetName : hostName + "_" + targetName,
			component: "Microsoft.VisualStudio.Component.VC.Tools." + (target == TargetArch.Arm64 ? "ARM64" : "x86.x64")
		};
	}

	static function archName(arch:TargetArch):Null<String>
		return arch == TargetArch.X64 ? "x64" : arch == TargetArch.Arm64 ? "arm64" : arch == TargetArch.X86 ? "x86" : null;

	/** The machine's architecture, also from a 32-bit process, which Windows tells through PROCESSOR_ARCHITEW6432. */
	static function hostArch():TargetArch {
		var wow = Sys.getEnv("PROCESSOR_ARCHITEW6432"),
			name = wow != null ? wow : Sys.getEnv("PROCESSOR_ARCHITECTURE");
		return name == "ARM64" ? TargetArch.Arm64 : name == "x86" ? TargetArch.X86 : TargetArch.X64;
	}

	/** Whether this process already has a developer environment for the host and target. */
	static function active(tools:MsvcToolset):Bool
		return Sys.getEnv("VCINSTALLDIR") != null
			&& lower(Sys.getEnv("VSCMD_ARG_TGT_ARCH")) == tools.targetName
			&& lower(Sys.getEnv("VSCMD_ARG_HOST_ARCH")) == tools.hostName;

	static function lower(value:Null<String>):Null<String>
		return value == null ? null : value.toLowerCase();

	static function load(tools:MsvcToolset):Bool {
		var programs = Sys.getEnv("ProgramFiles(x86)");
		if (programs == null)
			return false;
		var vswhere = Path.join([programs, "Microsoft Visual Studio", "Installer", "vswhere.exe"]);
		if (!FileSystem.exists(vswhere))
			return false;
		var install = HostCommand.text(vswhere, ["-latest", "-products", "*", "-requires", tools.component, "-property", "installationPath"]);
		if (install == null || install.length == 0)
			return false;
		var vcvars = StringTools.replace(Path.join([install.split("\n")[0], "VC", "Auxiliary", "Build", "vcvarsall.bat"]), "/", "\\");
		if (!FileSystem.exists(vcvars))
			return false;
		// Without an argument list the line runs through `cmd /C`. The inner `cmd /u` makes `set` print UTF-16, so values
		// outside the OEM code page (a user name in a path, say) arrive intact.
		var listing = HostCommand.output('cmd /u /c ""$vcvars" ${tools.argument} >nul 2>&1 && set"', null);
		if (listing == null)
			return false;
		for (line in utf16(listing).split("\r\n")) {
			var separator = line.indexOf("=");
			if (separator <= 0)
				continue;
			var name = line.substr(0, separator), value = line.substr(separator + 1);
			if (Sys.getEnv(name) != value)
				Sys.putEnv(name, value);
		}
		return active(tools);
	}

	/** Little-endian UTF-16, as `cmd /u` writes it. */
	static function utf16(bytes:Bytes):String {
		var text = new StringBuf(), index = 0;
		while (index + 1 < bytes.length) {
			var unit = bytes.get(index) | (bytes.get(index + 1) << 8);
			index += 2;
			if (unit >= 0xD800 && unit < 0xDC00 && index + 1 < bytes.length) {
				var low = bytes.get(index) | (bytes.get(index + 1) << 8);
				if (low >= 0xDC00 && low < 0xE000) {
					index += 2;
					unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
				}
			}
			text.addChar(unit);
		}
		return text.toString();
	}
}

/** See `MsvcEnvironment.toolset`. */
typedef MsvcToolset = {
	final hostName:String;
	final targetName:String;
	final argument:String;
	final component:String;
}
