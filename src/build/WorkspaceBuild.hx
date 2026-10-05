package build;

import build.BuildEnvironment.BuildProfile;
import build.execution.ActionId;
import build.execution.ActionMerge;
import build.execution.ExecutionAction;
import build.execution.ExecutionPlan;
import build.WorkspaceManifest.WorkspaceProject;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import build.native.NativeCMakeProvider;
import haxe.io.Path;
import project.ResolvedProject;

/** A member project's share of the merged plan. */
class LoweredWorkspaceProject {
	public final name:String;
	public final project:ResolvedProject;

	/** Where this project's module lands, matching a standalone `haxeon build`. */
	public final output:String;

	public final actions:Array<ActionId>;

	/** See `WorkspaceProject.cacheTests` and `testInputs`. */
	public final cacheTests:Bool;

	public final testInputs:Array<String>;

	/** See `WorkspaceProject.shards`. */
	public final shards:Int;

	public function new(name:String, project:ResolvedProject, output:String, actions:Array<ActionId>, cacheTests:Bool = true, ?testInputs:Array<String>,
			shards:Int = 1) {
		this.name = name;
		this.project = project;
		this.output = output;
		this.actions = actions.copy();
		this.cacheTests = cacheTests;
		this.testInputs = testInputs == null ? [] : testInputs.copy();
		this.shards = shards;
	}
}

class LoweredWorkspace {
	public final environment:BuildEnvironment;
	public final plan:ExecutionPlan;
	public final projects:Array<LoweredWorkspaceProject>;

	/** Actions before merging, summed over projects. */
	public final rawActionCount:Int;

	/** For each merged action, the projects that requested it. */
	public final requestedBy:Map<String, Array<String>>;

	public function new(environment:BuildEnvironment, plan:ExecutionPlan, projects:Array<LoweredWorkspaceProject>, rawActionCount:Int,
			requestedBy:Map<String, Array<String>>) {
		this.environment = environment;
		this.plan = plan;
		this.projects = projects.copy();
		this.rawActionCount = rawActionCount;
		this.requestedBy = requestedBy;
	}
}

/**
 * Lowers several projects onto one shared build root and merges their actions into a single graph. Actions
 * with the same identity are one node: identical work requested by many projects runs once, and a node
 * that differs between projects is a conflict rather than a silent overwrite.
 */
class WorkspaceBuild {
	public static function lower(workspace:WorkspaceManifest, projects:Array<WorkspaceProject>, resolve:String->ResolvedProject, home:String,
			defines:Array<String>):LoweredWorkspace {
		var environment = new BuildEnvironment(workspace.root, workspace.buildRoot, BuildProfile.Release), merged = new Map<String, ExecutionAction>(),
			order:Array<String> = [], requestedBy = new Map<String, Array<String>>(), lowered:Array<LoweredWorkspaceProject> = [], raw = 0;
		for (member in projects) {
			var project = resolve(member.manifestPath);
			if (project.manifest.target != "host")
				throw 'Workspace project "${member.name}" targets "${project.manifest.target}"; workspace builds support "host" only';
			var output = Path.join([project.root, project.manifest.outputDir, "host", "main.hl"]),
				plan = BuildPlanner.project(project, BuildIntent.Build, environment.target, NativeArtifactDemand.Shared),
				execution = PlanLowerer.lower(plan, new LoweringContext(environment, null, project, output, home, defines, false, true)),
				ids:Array<ActionId> = [];
			for (action in execution.actions) {
				var key = action.id.key(), existing = merged.get(key);
				if (existing == null) {
					merged.set(key, action);
					order.push(key);
					requestedBy.set(key, [member.name]);
				} else {
					merged.set(key, ActionMerge.combine(existing, action, requestedBy.get(key).join(", "), member.name));
					requestedBy.get(key).push(member.name);
				}
				ids.push(action.id);
				raw++;
			}
			lowered.push(new LoweredWorkspaceProject(member.name, project, output, ids, member.cacheTests, member.testInputs, member.shards));
		}
		return new LoweredWorkspace(environment, new ExecutionPlan([for (key in order) merged.get(key)]), lowered, raw, requestedBy);
	}

	/**
	 * Adds one `test:<name>` action per project. It runs the project's module once everything built for it, the compile
	 * and the native libraries the module loads, has finished. Output goes to a per-project log so
	 * concurrent tests do not interleave; a failing test prints the tail of its log.
	 *
	 * A project with `shards` of N runs its module N times, as `test:<name>#<I>of<N>` actions that share the one compile and
	 * run side by side, each with `--shard I/N`. Each has its own log and its own cached result, so an edit that leaves a
	 * shard's inputs unchanged does not rerun it.
	 */
	public static function withTests(workspace:LoweredWorkspace, home:String, useCache:Bool = true):ExecutionPlan {
		if (Sys.systemName() == "Windows")
			throw "Workspace tests currently run on Linux and macOS only";
		var actions = workspace.plan.actions.copy(),
			context = new LoweringContext(workspace.environment, null, null, null, home, [], false, true),
			hashlink = Path.join([home, ".tools", "hashlink", "hl"]),
			variable = Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH",
			existing = Sys.getEnv(variable),
			runtime = runtimeFiles(home);
		for (member in workspace.projects) {
			var compile:Null<ActionId> = null;
			for (id in member.actions)
				if (StringTools.startsWith(id.key(), "compile-project:"))
					compile = id;
			if (compile == null)
				throw 'Workspace project "${member.name}" has no compile action to test';
			var directories = [Path.join([home, "out"]), Path.join([home, ".tools", "hashlink"])], // What a passing run depends on besides the compile action: the module, the HashLink runtime,
			// the native libraries it loads, and the files beside its project. The project directory
			// stands in for test data; list data kept elsewhere under `inputs` in the workspace file.
				inputs = [member.output, member.project.root].concat(runtime).concat(member.testInputs);
			for (resolvedPackage in member.project.packages.packages) {
				var packageRoot = context.layout.packageRoot(resolvedPackage.name);
				directories.push(packageRoot);
				inputs.push(packageRoot);
				var sharedOutput = NativeCMakeProvider.sharedOutputDirectory(resolvedPackage, context);
				if (sharedOutput != null) {
					directories.push(sharedOutput);
					inputs.push(sharedOutput);
				}
			}
			if (existing != null && existing.length > 0)
				directories.push(existing);
			var testsDirectory = Path.join([workspace.environment.buildRoot, "tests"]),
				environment = [variable => directories.join(":")];
			for (shard in 1...member.shards + 1) {
				var sharded = member.shards > 1,
					runName = sharded ? member.name + "#" + shard + "of" + member.shards : member.name,
					safeName = StringTools.replace(runName, "/", "-"),
					log = Path.join([testsDirectory, safeName + ".log"]),
					stamp = Path.join([testsDirectory, safeName + ".passed"]), // The stamp exists only while the last run of this action passed; the executor skips the run
				// when it exists and every input is unchanged since a passing run.
					arguments = sharded ? " --shard " + shard + "/" + member.shards : "",
					script = 'mkdir -p ${quote(testsDirectory)} && rm -f ${quote(stamp)} && ${quote(hashlink)} ${quote(member.output)}$arguments > ${quote(log)} 2>&1; status=$$?; '
						+ 'if [ $$status -eq 0 ]; then tail -n 1 ${quote(log)}; touch ${quote(stamp)}; else tail -n 40 ${quote(log)}; fi; exit $$status';
				actions.push(new ExecutionAction(new ActionId("test:" + runName), member.actions, inputs, [stamp], 'Test $runName (log: $log)',
					Process("sh", ["-c", script], member.project.root, environment), true, !(useCache && member.cacheTests)));
			}
		}
		return new ExecutionPlan(actions);
	}

	/** HashLink and Haxeon runtime libraries a module loads, without the many compiled programs beside them. */
	static function runtimeFiles(home:String):Array<String> {
		var files:Array<String> = [];
		for (directory in [Path.join([home, ".tools", "hashlink"]), Path.join([home, "out"])])
			if (sys.FileSystem.exists(directory) && sys.FileSystem.isDirectory(directory))
				for (entry in sys.FileSystem.readDirectory(directory)) {
					var path = Path.join([directory, entry]);
					if (!sys.FileSystem.isDirectory(path)
						&& (entry == "hl"
							|| StringTools.endsWith(entry, ".hdll")
							|| StringTools.endsWith(entry, ".so")
							|| entry.indexOf(".so.") > 0
							|| StringTools.endsWith(entry, ".dylib")))
						files.push(path);
				}
		return files;
	}

	static function quote(value:String):String
		return "'" + StringTools.replace(value, "'", "'\\''") + "'";
}
