package build.provider;

import build.Target.TargetOs;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.lowering.LoweringContext;
import compiler.core.UsageError;
import haxe.Json;
import haxe.io.Path;
import project.ResolvedProject;
import project.ShaderInputs;
import sys.FileSystem;
import sys.io.File;

class ShaderProvider {
	static inline final ACTION_PREFIX = "compile-shaders:";

	public static function owns(id:ActionId):Bool
		return StringTools.startsWith(id.key(), ACTION_PREFIX);

	public static function action(project:ResolvedProject, context:LoweringContext,
			output:String):Null<ExecutionAction> {
		var roots = ShaderInputs.roots(project), variants = projectVariants(project);
		var manifest = ShaderInputs.sources(output);
		if (roots.length == 0 && Reflect.fields(variants).length == 0
			&& (!FileSystem.exists(manifest) || File.getContent(manifest) == ""))
			return null;
		var target = switch context.environment.target.os {
			case Linux: "glsl410";
			case Wasm | Android: "glsl300es";
			case Windows: "hlsl5";
			case MacOS: "metal_macos";
			case Other("ios"): "metal_ios";
			case Other(name): throw new UsageError('Shader generation does not support $name');
		};
		var tools = HaxeonSdk.shaderTools(context.compilerHome);
		var args = [
			tools.build,
			"--driver", tools.driver,
			"--generator", tools.generator,
			"--output", output,
			"--project", project.root,
			"--target", target,
			"--diagnostics", Std.string(context.reportStyle.diagnosticFormat),
			"--variants", Json.stringify(variants)
		].concat(roots);
		var python = Sys.getEnv("HAXEON_SHADER_PYTHON");
		if (python == null || python == "")
			python = Sys.systemName() == "Windows" ? "python" : "python3";
		var inputs = [tools.build, tools.driver, tools.generator];
		var outputs = [ShaderInputs.sources(output), ShaderInputs.dependencies(output)];
		// The shader tool checks its inputs per module and rewrites changed output.
		return new ExecutionAction(new ActionId(ACTION_PREFIX + project.rootPackage.name), [], inputs, outputs,
			"Generate shader modules",
			Process(python, args, project.root, []), false, true);
	}

	static function projectVariants(project:ResolvedProject):Dynamic {
		var value = {};
		for (item in project.packages.packages) {
			for (module => entries in item.manifest.shaderVariants) {
				var rows = {};
				for (name => defines in entries)
					Reflect.setField(rows, name, defines);
				if (Reflect.hasField(value, module))
					throw new UsageError('Multiple packages declare shader variants for $module');
				Reflect.setField(value, module, rows);
			}
		}
		return value;
	}
}
