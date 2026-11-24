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
		var roots = ShaderInputs.roots(project), variants = project.manifest.shaderVariants;
		var manifest = ShaderInputs.sources(output);
		if (roots.length == 0 && !variants.iterator().hasNext()
			&& (!FileSystem.exists(manifest) || File.getContent(manifest) == ""))
			return null;
		var target = switch context.environment.target.os {
			case Linux: "glsl410";
			case Wasm | Android: "glsl300es";
			case Windows: "hlsl5";
			case MacOS: "metal_macos";
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
			"--variants", variantsJson(variants)
		].concat(roots);
		var python = Sys.getEnv("HAXEON_SHADER_PYTHON");
		if (python == null || python == "")
			python = Sys.systemName() == "Windows" ? "python" : "python3";
		var inputs = [tools.build, tools.driver, tools.generator];
		var outputs = [ShaderInputs.sources(output), ShaderInputs.dependencies(output)];
		// The shader tool checks its dependency graph and compiler digest per module; it only rewrites changed output.
		return new ExecutionAction(new ActionId(ACTION_PREFIX + project.rootPackage.name), [], inputs, outputs,
			"Generate shader modules",
			Process(python, args, project.root, []), false, true);
	}

	static function variantsJson(variants:Map<String, Map<String, Array<String>>>):String {
		var value = {};
		for (module => entries in variants) {
			var rows = {};
			for (name => defines in entries)
				Reflect.setField(rows, name, defines);
			Reflect.setField(value, module, rows);
		}
		return Json.stringify(value);
	}
}
