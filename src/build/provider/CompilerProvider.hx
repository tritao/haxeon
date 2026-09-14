package build.provider;

import build.BuildEnvironment;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ProcessRunner;
import project.ResolvedProject;

/** One project-level request to the persistent Haxeon compiler service. */
class CompilerProvider {
	public static function action(project:ResolvedProject, environment:BuildEnvironment, actionId:ActionId, dependencies:Array<ActionId>, output:String,
			compilerHome:String, ?extraDefines:Array<String>):ExecutionAction {
		if (project.manifest.entry == null)
			throw 'Root package "${project.rootPackage.name}" must declare an "entry" for a build';
		var compiler = haxe.io.Path.join([
			compilerHome,
			".tools",
			"haxe",
			"haxe" + (Sys.systemName() == "Windows" ? ".exe" : "")
		]), compilerSource = Sys.getEnv("HAXEON_COMPILER_SOURCE"), arguments = [
			"-cp",
			compilerSource == null || compilerSource == "" ? haxe.io.Path.join([compilerHome, "src"]) : compilerSource,
			"--run",
			"compiler.tools.HaxeonCompiler",
			"--target=" + (project.manifest.target == "host" ? "hl" : project.manifest.target),
			"--output=" + output,
			"--entry=" + project.manifest.entry
			], inputs:Array<String> = [];
		for (resolvedPackage in project.packages.packages) {
			for (sourceRoot in resolvedPackage.sourceRoots)
				arguments.push("--root=" + sourceRoot);
			var shouldScopeRoot = resolvedPackage.name != project.rootPackage.name
				|| project.manifest.entry == resolvedPackage.name
				|| StringTools.startsWith(project.manifest.entry, resolvedPackage.name + ".");
			if (shouldScopeRoot)
				for (sourceRoot in resolvedPackage.sourceRoots)
					arguments.push('--package-root=${resolvedPackage.name}=$sourceRoot');
			for (source in resolvedPackage.sources) {
				arguments.push(source);
				inputs.push(source);
			}
		}
		for (define in project.manifest.defines.concat(extraDefines == null ? [] : extraDefines))
			arguments.push("--define=" + define);
		return new ExecutionAction(actionId, dependencies, inputs, [output], 'Compile Haxe package "${project.rootPackage.name}" -> $output',
			Compiler('Haxeon ${project.manifest.target} compilation', () -> ProcessRunner.run(compiler, arguments, compilerHome, new Map())));
	}
}
