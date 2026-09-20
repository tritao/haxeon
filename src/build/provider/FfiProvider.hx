package build.provider;

import build.Target;
import build.Target.TargetAbi;
import build.Target.TargetArch;
import build.Target.TargetOs;
import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import haxe.io.Path;
import project.FfiManifest.ResolvedFfiImport;
import project.ResolvedPackage;

/** Lowers a project FFI recipe into a deterministic header-import action. */
class FfiProvider {
	public static function action(resolvedPackage:ResolvedPackage, ffi:ResolvedFfiImport, context:LoweringContext, actionId:ActionId,
			output:String):ExecutionAction {
		var useWrapper = Sys.systemName() != "Windows",
			compiler = useWrapper ? Path.join([context.compilerHome, "scripts", "haxeon-ffi-import"]) : Path.join([context.compilerHome, ".tools", "haxe", "haxe.exe"]),
			projectionDirectory = context.layout.ffiProjectionPath(resolvedPackage.name, ffi.config.name),
			projectionManifest = context.layout.ffiProjectionManifestPath(resolvedPackage.name, ffi.config.name), arguments = [
				"--manifest=" + ffi.manifestPath,
				"--target=" + clangTarget(context.environment.target),
				"--output=" + output
			], inputs = ffi.inputs(), outputs = [output], thunkSource = context.layout.ffiThunkSourcePath(resolvedPackage.name, ffi.config.name);
		if (!useWrapper) {
			arguments.unshift("FfiImportMain");
			arguments.unshift("--run");
			arguments.unshift(Path.join([context.compilerHome, "src"]));
			arguments.unshift("-cp");
		}
		if (useWrapper)
			inputs.push(Path.join([context.compilerHome, "scripts", "haxeon-ffi-import"]));
		inputs.push(Path.join([context.compilerHome, "src"]));
		if (ffi.config.cxxThunks) {
			arguments.push("--library=" + context.layout.ffiNativeLibraryPath(resolvedPackage.name, ffi.config.name));
			arguments.push("--cxx-thunks=" + thunkSource);
			outputs.push(thunkSource);
		}
		if (ffi.config.projection) {
			arguments.push("--haxe-output-dir=" + projectionDirectory);
			arguments.push("--haxe-source-manifest=" + projectionManifest);
			outputs.push(projectionDirectory);
			outputs.push(projectionManifest);
		}
		return new ExecutionAction(actionId, [], inputs, outputs, 'Import ${ffi.config.language} FFI ${ffi.config.name} -> $output',
			Process(compiler, arguments, context.compilerHome, new Map()));
	}

	public static function clangTarget(target:Target):String {
		var architecture = switch target.arch {
			case TargetArch.X64: "x86_64";
			case TargetArch.Arm64: target.os == TargetOs.MacOS ? "arm64" : "aarch64";
			case _: throw 'FFI imports do not support target architecture ${Target.archName(target.arch)}';
		};
		return switch target.os {
			case TargetOs.Linux: architecture + "-linux-gnu";
			case TargetOs.MacOS: architecture + "-apple-darwin";
			case TargetOs.Windows:
				switch target.abi {
					case TargetAbi.Msvc: architecture + "-pc-windows-msvc";
					case _: architecture + "-w64-windows-gnu";
				}
			case TargetOs.Android: architecture + "-linux-android";
			case _: throw 'FFI imports do not support target ${target.toString()}';
		};
	}
}
