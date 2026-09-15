package build.native;

import build.BuildEnvironment;
import build.Target.TargetOs;

/** Small host-only command selector for compiling and linking native C. */
class NativeToolchain {
	final environment:BuildEnvironment;

	public function new(environment:BuildEnvironment)
		this.environment = environment;

	public function compileCommand():String
		return environment.toolchain.cCompiler;

	public function compileArguments(source:String, output:String, includeDirs:Array<String>):Array<String> {
		var arguments:Array<String> = [];
		switch environment.target.os {
			case Windows:
				arguments = ["/nologo", "/c", source, "/Fo" + output];
				for (directory in includeDirs)
					arguments.push("/I" + directory);
		case _:
			arguments = ["-c", source, "-o", output];
			if (environment.target.os != TargetOs.Windows)
				arguments.push("-fPIC");
			arguments = environment.toolchain.compileFlags.concat(arguments);
			for (directory in includeDirs)
				arguments.push("-I" + directory);
		}
		return arguments;
	}

	public function archiveCommand():String
		return environment.toolchain.archiver;

	public function archiveArguments(output:String, objects:Array<String>):Array<String>
		return environment.target.os == TargetOs.Windows ? ["/nologo", "/OUT:" + output].concat(objects) : ["rcs", output].concat(objects);

	public function sharedCommand():String
		return environment.toolchain.linker;

	public function sharedArguments(output:String, objects:Array<String>):Array<String> {
		var arguments = switch environment.target.os {
			case TargetOs.Windows: ["/nologo", "/LD", "/Fe:" + output].concat(objects);
			case TargetOs.MacOS: ["-dynamiclib", "-o", output].concat(objects);
			case _: ["-shared", "-o", output].concat(objects);
		};
		return environment.toolchain.linkFlags.concat(arguments);
	}
}
