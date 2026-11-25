package build.native;

import build.Artifact;
import build.Target;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.lowering.LoweringContext;
import compiler.core.InternalError;
import haxe.io.Path;

/**
 * A console program's release build: the executable compiled ahead of time with the libraries of its native packages beside
 * it, in `build/<platform>/bin/`, the directory to ship, as an app's runner puts its own in `build/<platform>/app/`. An app's
 * runner builds its native packages again in its own CMake graph, since the runner must also build without `haxeon`; a
 * console program has no runner, so its packages are the ones this build already built, and are only copied.
 */
class ConsoleProgram {
	/** The CMake tree the program is built in; `bin/` inside it holds what ships. */
	public static function directory(buildDirectory:String, target:Target):String
		return Path.join([buildDirectory, Target.osName(target.os)]);

	/** Where the executable of the program named `name` is written. */
	public static function executablePath(buildDirectory:String, target:Target, name:String):String
		return Path.join([
			directory(buildDirectory, target),
			"bin",
			name + (target.os == TargetOs.Windows ? ".exe" : "")
		]);

	/**
	 * Configures the SDK's `cmake/aot` project for the C the compiler writes at `module`, builds the executable, and publishes
	 * the shared libraries that the actions of `executable`'s native dependencies produced beside it.
	 */
	public static function lower(executable:Artifact, module:String, buildDirectory:String, context:LoweringContext,
			lowered:Array<ExecutionAction>, artifactActions:Map<String, Array<ActionId>>):Array<ExecutionAction> {
		var project = context.project;
		if (project == null)
			throw new InternalError("A console program's release build needs its project");
		var target = context.environment.target,
			sdk = context.compilerHome,
			cmake = HaxeonSdk.cmakeDirectory(sdk),
			source = Path.join([cmake, "aot"]),
			tree = directory(buildDirectory, target),
			output = executablePath(buildDirectory, target, project.rootPackage.name),
			shipped = Path.directory(output),
			key = executable.id.key(),
			configureId = new ActionId('program-configure:$key'),
			buildId = new ActionId('program-build:$key'),
			shipId = new ActionId('program-ship:$key'),
			moduleActions:Array<ActionId> = [],
			libraryActions:Array<ActionId> = [];
		for (dependency in executable.dependencies) {
			var actions = artifactActions.get(dependency.key());
			if (actions == null)
				throw new InternalError('No lowered action for required artifact $dependency');
			if (dependency.kind == ArtifactKind.CModule)
				moduleActions = moduleActions.concat(actions);
			else
				libraryActions = libraryActions.concat(actions);
		}
		// The libraries are whatever those actions declare; one action can also declare an import library or a stamp.
		var libraries:Array<String> = [],
			library = ~/\.(so(\.[0-9]+)*|dylib|dll|hdll)$/,
			libraryKeys = [for (id in libraryActions) id.key()];
		for (action in lowered)
			if (libraryKeys.indexOf(action.id.key()) >= 0)
				for (file in action.outputs)
					if (library.match(file) && libraries.indexOf(file) < 0)
						libraries.push(file);
		libraries.sort(Reflect.compare);
		var from:Array<String> = [];
		for (file in libraries)
			if (from.indexOf(Path.directory(file)) < 0)
				from.push(Path.directory(file));
		// A tree another SDK's copy of the project configured would be refused by CMake.
		NativeCMakeProvider.discardCacheOfOtherSource(tree, source);
		var generator = NativeCMakeProvider.generatorArguments(target, sdk),
			configureArguments = [
				"-S",
				source,
				"-B",
				tree,
				"-DHaxeon_DIR=" + cmake,
				"-DC_SOURCES=" + module + ".c",
				"-DOUTPUT=" + Path.join([shipped, project.rootPackage.name])
			].concat(generator),
			// The project globs the C at configure time, so it waits for the compile; a later compile changes what CMake builds,
			// not how it is configured.
			configure = new ExecutionAction(configureId, moduleActions, [
				Path.join([source, "CMakeLists.txt"]),
				Path.join([cmake, "HaxeonConfig.cmake"]),
				Path.join([cmake, "HaxeonApp.cmake"])
			], [Path.join([
				tree,
				"CMakeCache.txt"
			])], 'Configure console program ${project.rootPackage.name}',
				Process("cmake", configureArguments, context.environment.projectRoot, new Map()), false, false, false,
				null,
				false),
			// The executable carries this project's source paths for its stack traces, so it is never shared.
			build = new ExecutionAction(buildId, [configureId].concat(moduleActions), [module + ".c"], [output],
				'Build console program -> $output',
				Process("cmake", ["--build", tree], context.environment.projectRoot, new Map()),
				true, true, generator.length > 0, null, false),
			// One publish for every library, so its record of what it copied covers them all: a library no longer needed is
			// removed again.
			ship = new ExecutionAction(shipId, libraryActions, libraries.concat([Path.join([
				cmake,
				"haxeon-publish.cmake"
			])]),
				[for (file in libraries) Path.join([shipped, Path.withoutDirectory(file)])].concat([Path.join([
					shipped,
					".haxeon-published"
				])]),
				'Ship native libraries -> $shipped', Process("cmake", [
					"-DFROM=" + from.join(";"),
					"-DTO=" + shipped,
					"-P",
					Path.join([cmake, "haxeon-publish.cmake"])
				], context.environment.projectRoot, new Map()), true, false, false, null, false);
		artifactActions.set(key, [buildId, shipId]);
		return [configure, build, ship];
	}
}
