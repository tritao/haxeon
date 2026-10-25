package build.native;

import build.BuildEnvironment;
import build.Target.TargetAbi;
import build.Target.TargetOs;

/** Small host-only command selector for compiling and linking native C. */
class NativeToolchain {
	final environment:BuildEnvironment;
	final compilerHome:Null<String>;

	/** compilerHome locates the hooks that natively instrumented modules link; without it nothing is instrumented. */
	public function new(environment:BuildEnvironment, ?compilerHome:String) {
		this.environment = environment;
		this.compilerHome = compilerHome;
	}

	/**
	 * Whether this build instruments native code: the instrumented flavor on MSVC x64, which compiles the sources in the
	 * manifest's native scope with `/Gh /GH` and links the hooks HashLink builds (`hlprof_penter.lib`).
	 */
	public function instrumenting():Bool {
		var target = environment.target;
		return environment.instrument != null
			&& compilerHome != null
			&& target.os == TargetOs.Windows
			&& target.abi == TargetAbi.Msvc
			&& target.arch == build.Target.TargetArch.X64;
	}

	/** Whether source (absolute, or relative to root) is in the native scope; patterns match it relative to root or absolute. */
	public function instruments(source:String, root:String):Bool {
		if (!instrumenting())
			return false;
		var absolute = haxe.io.Path.normalize(haxe.io.Path.isAbsolute(source) ? source : haxe.io.Path.join([root, source])),
			prefix = haxe.io.Path.addTrailingSlash(haxe.io.Path.normalize(root)),
			relative = StringTools.startsWith(absolute, prefix) ? absolute.substr(prefix.length) : absolute;
		inline function matches(patterns:Array<String>):Bool {
			var found = false;
			for (pattern in patterns)
				if (!found) {
					var regex = globRegex(pattern);
					found = regex.match(relative) || regex.match(absolute);
				}
			return found;
		}
		return matches(environment.instrument.nativeInclude) && !matches(environment.instrument.nativeExclude);
	}

	public function instrumentHooks():String
		return haxe.io.Path.join([compilerHome, ".tools", "hashlink", "hlprof_penter.lib"]);

	/** `*` within a path component, `**` across components, `?` one character (as in cmake/haxeon-instrument.cmake). */
	static function globRegex(pattern:String):EReg {
		var out = new StringBuf(), i = 0;
		while (i < pattern.length) {
			var c = pattern.charAt(i);
			if (c == "*" && pattern.charAt(i + 1) == "*") {
				if (pattern.charAt(i + 2) == "/") {
					out.add("(.*/)?");
					i += 3;
				} else {
					out.add(".*");
					i += 2;
				}
				continue;
			}
			out.add(switch c {
				case "*": "[^/]*";
				case "?": "[^/]";
				case _ if ("\\^$.|+()[]{}".indexOf(c) >= 0): "\\" + c;
				case _: c;
			});
			i++;
		}
		return new EReg("^" + out.toString() + "$", "");
	}

	public function compileCommand(source:String):String
		return isCxxSource(source) ? environment.toolchain.cxxCompiler : environment.toolchain.cCompiler;

	public function isCxxSource(source:String):Bool {
		var extension = haxe.io.Path.extension(source).toLowerCase();
		return extension == "cc" || extension == "cpp" || extension == "cxx" || extension == "mm";
	}

	/** instrumentRoot is the root native scope patterns are relative to; without it the source is not instrumented. */
	public function compileArguments(source:String, output:String, includeDirs:Array<String>, ?standard:String, ?instrumentRoot:String):Array<String> {
		var arguments:Array<String> = [];
		switch environment.target.os {
			case Windows:
				if (environment.target.abi == TargetAbi.Msvc) {
					arguments = ["/nologo", "/c", source, "/Fo" + output];
					if (instrumenting())
						arguments.push("/Z7");
					if (instrumentRoot != null && instruments(source, instrumentRoot))
						arguments = arguments.concat(["/Gh", "/GH"]);
					if (isCxxSource(source) && standard != null)
						arguments.unshift("/std:" + standard);
					for (directory in includeDirs)
						arguments.push("/I" + directory);
				} else {
					arguments = ["-c", source, "-o", output];
					if (isCxxSource(source) && standard != null)
						arguments.unshift("-std=" + standard);
					for (directory in includeDirs)
						arguments.push("-I" + directory);
				}
			case _:
				arguments = ["-c", source, "-o", output];
				if (environment.target.os != TargetOs.Windows)
					arguments.push("-fPIC");
				if (isCxxSource(source) && standard != null)
					arguments.unshift("-std=" + standard);
				arguments = environment.toolchain.compileFlags.concat(arguments);
				for (directory in includeDirs)
					arguments.push("-I" + directory);
		}
		return arguments;
	}

	public function archiveCommand():String
		return environment.toolchain.archiver;

	public function archiveArguments(output:String, objects:Array<String>):Array<String>
		return environment.target.os == TargetOs.Windows
			&& environment.target.abi == TargetAbi.Msvc ? ["/nologo", "/OUT:" + output].concat(objects) : ["rcs", output].concat(objects);

	public function sharedCommand():String
		return environment.toolchain.linker;

	public function sharedArguments(output:String, objects:Array<String>, ?linkInputs:Array<String>, ?runtimeSearchPaths:Array<String>):Array<String> {
		var inputs = linkInputs == null ? [] : linkInputs,
			searchPaths = runtimeSearchPaths == null ? [] : runtimeSearchPaths;
		var arguments = switch environment.target.os {
			case TargetOs.Windows:
				environment.target.abi == TargetAbi.Msvc ? ["/nologo", "/LD", "/Fe:" + output].concat(objects)
				.concat(inputs)
				.concat(instrumenting() ? [instrumentHooks(), "/link", "/DEBUG", "/OPT:REF", "/OPT:ICF", "/INCREMENTAL:NO"] : []) : ["-shared", "-o", output].concat(objects)
				.concat(inputs);
			case TargetOs.MacOS: ["-dynamiclib", "-o", output].concat(objects).concat(inputs);
			case _: ["-shared", "-o", output].concat(objects).concat(inputs);
		};
		if (environment.target.os != TargetOs.Windows)
			for (searchPath in searchPaths)
				arguments.push("-Wl,-rpath," + searchPath);
		return environment.toolchain.linkFlags.concat(arguments);
	}
}
