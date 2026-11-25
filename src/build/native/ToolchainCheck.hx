package build.native;

import build.Target.TargetOs;
import sys.FileSystem;
import sys.io.File;

/**
 * What `haxeon doctor` checks of the machine's C and C++ toolchain: what an app's runner and a package with C or C++ code
 * (the UI package, for one) need to build, looked up the way their CMake builds find it, and the command that installs it.
 * It only looks: each check runs a tool's version query or `pkg-config`, and nothing is installed.
 */
class ToolchainCheck {
	/** The oldest CMake an app's runner takes (`cmake_minimum_required` in templates/app/linux/CMakeLists.txt). */
	static final minimumCMake = [3, 24];

	/** Prints an `ok:` or `missing:` line for each part of this machine's toolchain; true when something is missing. */
	public static function report():Bool {
		return check(false, (found, text) -> Sys.println('${found ? "ok" : "missing"}: $text'));
	}

	/**
	 * Fails with what is missing and the commands that install it, as `haxeon doctor` prints them, when this machine cannot
	 * build a program compiled ahead of time: a C compiler, CMake and a build tool. A console program needs neither the C++
	 * compiler nor the GUI libraries an app's window does; packages that need them say so when they build.
	 */
	public static function requireAheadOfTime():Void {
		var missing = [];
		if (check(true, (found, text) -> {
			if (!found)
				missing.push('missing: $text');
		}))
			throw new compiler.core.UsageError(missing.join("\n") + "\n" + installGuidance());
	}

	/** The commands that install the missing tools on this machine, as one paragraph. */
	public static function installGuidance():String
		return "Install what is missing with:\n  " + installCommands().join("\n  ");

	/** Reports each tool to `report`; with `program`, only what a program compiled ahead of time needs. */
	static function check(program:Bool, report:(Bool, String) -> Void):Bool {
		var host = Target.detectHost(), missing = false;
		function line(found:Bool, text:String):Void {
			report(found, text);
			if (!found)
				missing = true;
		}
		switch host.os {
			case TargetOs.Windows:
				// What a build does: load the developer environment of the newest Visual Studio with the C++ tools, which
				// also puts its CMake and Ninja on PATH.
				line(MsvcEnvironment.ensure(host.arch),
					"MSVC C and C++ compiler (Visual Studio Build Tools, found with vswhere)");
			case TargetOs.MacOS:
				// Without the command line tools, /usr/bin/cc is a stub that offers to install them, so ask xcode-select first.
				var developer = HostCommand.text("xcode-select", ["-p"]), tools = developer != null && developer != "";
				line(tools, tools ? 'Xcode command line tools ($developer)' : "Xcode command line tools");
				if (tools)
					compilers(line, program);
			case _:
				compilers(line, program);
		}
		var version = cmakeVersion();
		if (version == null)
			line(false, 'CMake ${minimumCMake.join(".")} or later (cmake)');
		else if (!atLeast(version, minimumCMake))
			line(false, 'CMake ${minimumCMake.join(".")} or later: cmake is ${version.join(".")}; '
				+ 'install a newer one from https://cmake.org/download/');
		else
			line(true, 'CMake ${version.join(".")}');
		if (host.os != TargetOs.Windows) {
			// Without Ninja, CMake writes Makefiles.
			var tool:Null<String> = null;
			for (name in ["ninja", "make"])
				if (tool == null && HostCommand.text(name, ["--version"]) != null)
					tool = name;
			line(tool != null, 'build tool (${tool != null ? tool : "ninja or make"})');
		}
		if (!program && host.os == TargetOs.Linux) {
			// The UI package's window is GTK 3 and draws with OpenGL; Fontconfig finds the system's fonts. pkg-config is how
			// their CMake finds GTK and Fontconfig.
			var pkgConfig = HostCommand.text("pkg-config", ["--version"]) != null;
			line(pkgConfig, "pkg-config");
			if (pkgConfig) {
				line(module("gtk+-3.0"), "GTK 3 development files (pkg-config gtk+-3.0)");
				line(module("gl"), "OpenGL development files (pkg-config gl)");
				line(module("fontconfig"), "Fontconfig development files (pkg-config fontconfig)");
			}
		}
		return missing;
	}

	/** The commands that install the toolchain on this system, one per line. */
	public static function installCommands():Array<String> {
		return switch Target.detectHost().os {
			case TargetOs.Windows: [
				'winget install Microsoft.VisualStudio.2022.BuildTools --override "--passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"',
				"winget install Kitware.CMake"
			];
			case TargetOs.MacOS: ["xcode-select --install", "brew install cmake ninja"];
			case _:
				var apt =
					"sudo apt-get install build-essential cmake ninja-build pkg-config libgtk-3-dev libgl1-mesa-dev libfontconfig1-dev",
					dnf =
						"sudo dnf install gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config gtk3-devel mesa-libGL-devel fontconfig-devel";
				switch linuxFamily() {
					case "debian": [apt];
					case "fedora": [dnf];
					case _: ['$apt   (Debian, Ubuntu)', '$dnf   (Fedora, RHEL)'];
				}
		};
	}

	static function compilers(line:(Bool, String) -> Void, program:Bool):Void {
		var c = compiler("CC", ["cc", "gcc", "clang"]);
		line(c != null, 'C compiler (${c != null ? c : "cc, gcc or clang"})');
		if (!program) {
			var cxx = compiler("CXX", ["c++", "g++", "clang++"]);
			line(cxx != null, 'C++ compiler (${cxx != null ? cxx : "c++, g++ or clang++"})');
		}
	}

	/** `CC` or `CXX` when set, else the first of `names` that runs: CMake's own order. Null when none runs. */
	static function compiler(variable:String, names:Array<String>):Null<String> {
		var chosen = Sys.getEnv(variable);
		if (chosen != null && chosen != "")
			return HostCommand.text(chosen, ["--version"]) != null ? chosen : null;
		for (name in names)
			if (HostCommand.text(name, ["--version"]) != null)
				return name;
		return null;
	}

	static function cmakeVersion():Null<Array<Int>> {
		var output = HostCommand.text("cmake", ["--version"]), pattern = ~/version ([0-9]+)\.([0-9]+)(\.([0-9]+))?/;
		if (output == null || !pattern.match(output))
			return null;
		var patch = pattern.matched(4);
		return [
			Std.parseInt(pattern.matched(1)),
			Std.parseInt(pattern.matched(2)),
			patch == null ? 0 : Std.parseInt(patch)
		];
	}

	static function atLeast(version:Array<Int>, minimum:Array<Int>):Bool
		return version[0] > minimum[0] || (version[0] == minimum[0] && version[1] >= minimum[1]);

	static function module(name:String):Bool
		return HostCommand.output("pkg-config", ["--exists", name]) != null;

	/** `debian` or `fedora` from /etc/os-release's `ID` and `ID_LIKE`, or null for another family. */
	static function linuxFamily():Null<String> {
		var path = "/etc/os-release";
		if (!FileSystem.exists(path))
			return null;
		var ids:Array<String> = [];
		for (line in File.getContent(path).split("\n")) {
			var separator = line.indexOf("=");
			if (separator <= 0)
				continue;
			var key = line.substr(0, separator);
			if (key == "ID" || key == "ID_LIKE")
				for (id in StringTools.replace(StringTools.replace(line.substr(separator + 1), '"', ""), "'",
					"").split(" "))
					ids.push(StringTools.trim(id));
		}
		for (id in ids)
			switch id {
				case "debian", "ubuntu":
					return "debian";
				case "fedora", "rhel", "centos":
					return "fedora";
				case _:
			}
		return null;
	}
}
