import build.Artifact;
import build.ArtifactId;
import build.BuildEnvironment;
import build.BuildIntent;
import build.BuildPlan;
import build.BuildPlanner;
import build.Target;
import build.TargetLayout;
import build.NativeArtifactDemand.NativeArtifactDemand;
import build.execution.ActionFingerprint;
import build.execution.ActionId;
import build.execution.ActionResult;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ExecutionPlan;
import build.execution.Executor;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import build.native.NativeDependencyScanner;
import haxe.io.Path;
import project.ProjectDiscovery;
import project.PackageManifest;
import project.PackageSourceTools;
import project.PackageResolver;
import project.PathSourceAcquirer;
import project.SourceAcquirer;
import sys.FileSystem;
import sys.io.File;
#if (target.threaded && !eval)
import sys.thread.Mutex;
#end

class BuildSystemMain {
	static function main():Void {
		testArtifactAndPlanDeterminism();
		testExecutorOrderingAndFailure();
		testIndependentProcessActionsRunConcurrently();
		#if (target.threaded && !eval)
		testIndependentActionsRunConcurrently();
		#end
		testFingerprintsAndSkipping();
		testProjectDiscovery();
		testPackageSourceModel();
		testResolverDelegatesAcquisition();
		testNativeDependencyScanning();
		Sys.println("PASS: build model, executor, fingerprints, demand-driven native outputs, and local package discovery");
	}

	static function testArtifactAndPlanDeterminism():Void {
		var target = Target.detectHost(),
			library = new ArtifactId("foo", ArtifactKind.NativeStaticLibrary, target),
			module = new ArtifactId("app", ArtifactKind.HashLinkModule, target),
			first = new BuildPlan([module], [new Artifact(module, [library]), new Artifact(library)]),
			second = new BuildPlan([new ArtifactId("app", ArtifactKind.HashLinkModule, target)], [
				new Artifact(new ArtifactId("app", ArtifactKind.HashLinkModule, target), [new ArtifactId("foo", ArtifactKind.NativeStaticLibrary, target)]),
				new Artifact(new ArtifactId("foo", ArtifactKind.NativeStaticLibrary, target))
			]);
		expect(module.equals(new ArtifactId("app", ArtifactKind.HashLinkModule, target)), "artifact identity should be deterministic");
		expect(!module.equals(new ArtifactId("app", ArtifactKind.HashLinkModule, target, "debug")), "artifact variants should distinguish identity");
		expect(module.toString().indexOf(target.toString()) >= 0, "artifact display should expose its target");
		expect(first.toDebugString() == second.toDebugString(), "plan output should not depend on insertion order");
		var cycleDetected = false;
		try {
			var left = new ArtifactId("left", ArtifactKind.Executable, target),
				right = new ArtifactId("right", ArtifactKind.Executable, target);
			new BuildPlan([left], [new Artifact(left, [right]), new Artifact(right, [left])]);
		} catch (_:Dynamic) {
			cycleDetected = true;
		}
		expect(cycleDetected, "artifact dependency cycles should be rejected");
	}

	static function testExecutorOrderingAndFailure():Void {
		var root = temporaryDirectory("executor"),
			environment = new BuildEnvironment(root, Path.join([root, "build"])),
			order:Array<String> = [];
		#if (target.threaded && !eval)
		var orderMutex = new Mutex();
		#end
		var record = function(value:String):Void {
			#if (target.threaded && !eval)
			orderMutex.acquire();
			#end
			order.push(value);
			#if (target.threaded && !eval)
			orderMutex.release();
			#end
		}, first = action("first", [], "first", () -> {
			record("first");
			0;
		}), second = action("second", [], "second", () -> {
			record("second");
			0;
		}), last = action("last", [first.id, second.id], "last", () -> {
			record("last");
			0;
		});
		var result = new Executor(environment, 4, _ -> {}).execute(new ExecutionPlan([last, second, first]));
		expect(result.exitCode == 0 && result.actions.length == 3, "independent actions should succeed before their dependent");
		expect(order.indexOf("last") > order.indexOf("first")
			&& order.indexOf("last") > order.indexOf("second"), "dependencies must complete first");

		var dependentRan = false,
			deepDependentRan = false,
			independentRan = false,
			failure = action("failure", [], "failure", () -> 37),
			independent = action("independent", [], "independent", () -> {
				independentRan = true;
				0;
			}),
			dependent = action("dependent", [failure.id], "dependent", () -> {
				dependentRan = true;
				0;
			}),
			deepDependent = action("deep-dependent", [dependent.id], "deep dependent", () -> {
				deepDependentRan = true;
				0;
			});
		var failed = new Executor(environment, 2, _ -> {}).execute(new ExecutionPlan([deepDependent, dependent, failure, independent]));
		expect(failed.exitCode == 37, "the original action exit status should propagate");
		expect(!dependentRan, "a failed dependency must prevent its consumer from executing");
		expect(!deepDependentRan, "failure should block every level of dependent actions");
		expect(independentRan, "actions unrelated to the failure should still be allowed to complete");
		removeTree(root);
	}

	static function testIndependentProcessActionsRunConcurrently():Void {
		if (Sys.systemName() != "Linux" && Sys.systemName() != "Mac")
			return;
		var root = temporaryDirectory("parallel-processes"),
			environment = new BuildEnvironment(root, Path.join([root, "build"])),
			leftStarted = Path.join([root, "left.started"]),
			rightStarted = Path.join([root, "right.started"]),
			leftDone = Path.join([root, "left.done"]),
			rightDone = Path.join([root, "right.done"]),
			leftScript = 'touch "$leftStarted"; for unused in 1 2 3 4 5 6 7 8 9 10; do if [ -f "$rightStarted" ]; then break; fi; sleep 0.05; done; test -f "$rightStarted" || exit 17; touch "$leftDone"',
			rightScript = 'touch "$rightStarted"; for unused in 1 2 3 4 5 6 7 8 9 10; do if [ -f "$leftStarted" ]; then break; fi; sleep 0.05; done; test -f "$leftStarted" || exit 19; touch "$rightDone"',
			left = new ExecutionAction(new ActionId("process-left"), [], [], [leftDone], "concurrent process left",
				Process("sh", ["-c", leftScript], root, new Map())),
			right = new ExecutionAction(new ActionId("process-right"), [], [], [rightDone], "concurrent process right",
				Process("sh", ["-c", rightScript], root, new Map())),
			result = new Executor(environment, 2, _ -> {}).execute(new ExecutionPlan([left, right]));
		expect(result.exitCode == 0 && FileSystem.exists(leftDone) && FileSystem.exists(rightDone),
			'independent external process actions should overlap on host targets (exit ${result.exitCode}, action statuses ${[for (action in result.actions) action.exitCode].join(",")}, ' +
			'markers: left=${FileSystem.exists(leftDone)}, right=${FileSystem.exists(rightDone)})');
		removeTree(root);
	}

	#if (target.threaded && !eval)
	static function testIndependentActionsRunConcurrently():Void {
		var root = temporaryDirectory("parallel"), environment = new BuildEnvironment(root, Path.join([root, "build"])), mutex = new Mutex(), active = 0,
			peakActive = 0;
		var invoke = function():Int {
			mutex.acquire();
			active++;
			if (active > peakActive)
				peakActive = active;
			mutex.release();
			Sys.sleep(0.15);
			mutex.acquire();
			active--;
			mutex.release();
			return 0;
		};
		var result = new Executor(environment, 2, _ -> {}).execute(new ExecutionPlan([
			action("parallel-a", [], "parallel A", invoke),
			action("parallel-b", [], "parallel B", invoke)
		]));
		expect(result.exitCode == 0 && peakActive == 2, "independent ready actions should overlap on threaded targets");
		removeTree(root);
	}
	#end

	static function testFingerprintsAndSkipping():Void {
		var root = temporaryDirectory("fingerprints"),
			buildRoot = Path.join([root, "build"]),
			source = Path.join([root, "source.c"]),
			includeDirectory = Path.join([root, "include"]),
			header = Path.join([includeDirectory, "first.h"]),
			output = Path.join([root, "artifact"]);
		FileSystem.createDirectory(includeDirectory);
		File.saveContent(source, "int value(void) { return 42; }\n");
		File.saveContent(header, "#define VALUE 42\n");
		File.saveContent(output, "artifact\n");
		var environment = new BuildEnvironment(root, buildRoot),
			actionValue = new ExecutionAction(new ActionId("compile-foo"), [], [source, includeDirectory], [output], "compile foo.c",
				Process("missing-tool-for-skip-test", [], root, new Map())),
			baseline = ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), []);
		ActionFingerprint.save(buildRoot, actionValue, baseline);
		var skipped = new Executor(environment, 1, _ -> {}).execute(new ExecutionPlan([actionValue]));
		expect(skipped.exitCode == 0 && skipped.actions[0].skipped, "unchanged action with existing outputs should be skipped");

		var changedArguments = new ExecutionAction(new ActionId("compile-foo"), [], [source, includeDirectory], [output], "compile foo.c",
			Process("missing-tool-for-skip-test", ["-O2"], root, new Map()));
		expect(ActionFingerprint.compute(changedArguments, buildRoot, environment.target.toString(), []) != baseline,
			"changed arguments should invalidate the action");
		expect(ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), ["dependency-a"]) != baseline,
			"changed dependencies should invalidate the action");
		var renamedHeader = Path.join([includeDirectory, "renamed.h"]);
		FileSystem.rename(header, renamedHeader);
		expect(ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), []) != baseline,
			"renamed headers should invalidate a directory input");
		File.saveContent(source, "int value(void) { return 43; }\n");
		expect(ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), []) != baseline,
			"changed source contents should invalidate the action");
		removeTree(root);
	}

	static function testProjectDiscovery():Void {
		var root = temporaryDirectory("discovery"),
			app = Path.join([root, "app"]),
			foo = Path.join([root, "foo"]),
			bar = Path.join([root, "bar"]);
		writePackage(app, '{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"dependencies":{"foo":{"path":"../foo"}}}',
			["src/Main.hx"]);
		writePackage(foo,
			'{"version":1,"package":{"name":"foo"},"sourceRoots":["src"],"dependencies":{"bar":{"path":"../bar"}},"native":{"sources":["native/foo.c"],"includeDirs":["native"]}}',
			["src/Foo.hx", "native/foo.c", "native/foo.h"]);
		writePackage(bar, '{"version":1,"package":{"name":"bar"},"sourceRoots":["src"]}', ["src/Bar.hx"]);
		var project = ProjectDiscovery.discover(Path.join([app, "haxeon.json"]));
		expect(project.rootPackage.name == "app", "root package should be identified");
		expect(project.packages.names().join(",") == "bar,foo,app", "nested packages should be ordered dependency-first");
		expect(project.packages.get("foo").nativeSources.length == 1 && project.packages.get("foo").includeDirs.length == 1,
			"native package metadata should be resolved");
		expect(project.rootPackage.sources.length == 1 && project.rootPackage.sources[0].indexOf("Main.hx") >= 0,
			"source roots should expand into a deterministic Haxe source manifest");
		var environment = new BuildEnvironment(project.root, Path.join([project.root, "build"])),
			plan = BuildPlanner.project(project, BuildIntent.Build, environment.target, NativeArtifactDemand.Shared),
			execution = PlanLowerer.lower(plan, new LoweringContext(environment, null, project, new TargetLayout(environment).hashLinkModulePath("main"), project.root)),
		executionText = execution.toDebugString();
		expect(plan.toExplainString().indexOf("reason: requested output") >= 0
			&& plan.toExplainString().indexOf("detail library: foo") >= 0,
			"plan explanations should identify requested outputs and provider details");
		expect(executionText.indexOf("kind: process") >= 0
			&& executionText.indexOf("kind: compiler (outer cache disabled)") >= 0
			&& executionText.indexOf("outputs:") >= 0,
			"execution plans should expose action kinds and outputs");
		expect(plan.toDebugString().indexOf("foo:NativeSharedLibrary") >= 0, "the package build plan should require its shared native library");
		expect(plan.toDebugString().indexOf("foo:NativeStaticLibrary") < 0, "the package build plan should not create an unrequested native archive");
		expect(executionText.indexOf("Compile C") >= 0
			&& executionText.indexOf("Archive foo") < 0
			&& executionText.indexOf("Link shared library foo") >= 0
			&& executionText.indexOf("Compile Haxe package") >= 0,
			"native sources, the requested shared library, and Haxe compilation should lower to concrete actions");
		expect(execution.actions[execution.actions.length - 1].description.indexOf("Compile Haxe package") >= 0,
			"the Haxe compiler request must follow native package actions");

		var staticPlan = BuildPlanner.project(project, BuildIntent.Build, environment.target, NativeArtifactDemand.Static),
			staticPlanText = staticPlan.toDebugString();
		expect(staticPlanText.indexOf("foo:NativeStaticLibrary") >= 0 && staticPlanText.indexOf("foo:NativeSharedLibrary") < 0,
			"an explicit static native demand should create only the archive");

		var missing = Path.join([root, "missing-app"]);
		writePackage(missing, '{"version":1,"package":{"name":"missing-app"},"entry":"Main","dependencies":{"foo":{"path":"../absent"}}}', ["src/Main.hx"]);
		expectThrows(() -> ProjectDiscovery.discover(Path.join([missing, "haxeon.json"])), "missing dependency paths should be reported");

		var duplicate = Path.join([root, "duplicate"]),
			first = Path.join([root, "first-shared"]),
			second = Path.join([root, "second-shared"]),
			nested = Path.join([duplicate, "foo"]);
		writePackage(duplicate, '{"version":1,"package":{"name":"duplicate"},"dependencies":{"foo":{"path":"foo"},"shared":{"path":"../first-shared"}}}', []);
		writePackage(nested, '{"version":1,"package":{"name":"foo"},"dependencies":{"shared":{"path":"../../second-shared"}}}', []);
		writePackage(first, '{"version":1,"package":{"name":"shared"}}', []);
		writePackage(second, '{"version":1,"package":{"name":"shared"}}', []);
		expectThrows(() -> ProjectDiscovery.discover(Path.join([duplicate, "haxeon.json"])), "duplicate package names should be reported");

		var cycle = Path.join([root, "cycle"]),
			child = Path.join([cycle, "child"]);
		writePackage(cycle, '{"version":1,"package":{"name":"cycle"},"dependencies":{"child":{"path":"child"}}}', []);
		writePackage(child, '{"version":1,"package":{"name":"child"},"dependencies":{"cycle":{"path":".."}}}', []);
		expectThrows(() -> ProjectDiscovery.discover(Path.join([cycle, "haxeon.json"])), "path dependency cycles should be reported");
		removeTree(root);
	}

	static function testNativeDependencyScanning():Void {
		var root = temporaryDirectory("native-dependencies"),
			includeDirectory = Path.join([root, "include"]),
			source = Path.join([root, "source.c"]),
			first = Path.join([includeDirectory, "first.h"]),
			second = Path.join([includeDirectory, "second.h"]);
		ensureDirectory(includeDirectory);
		File.saveContent(source, '#include "first.h"\nint value(void) { return SECOND; }\n');
		File.saveContent(first, '#include "second.h"\n');
		File.saveContent(second, '#define SECOND 42\n');
		var dependencies = NativeDependencyScanner.dependencies(source, [includeDirectory]);
		expect(dependencies.length == 2 && dependencies[0].indexOf("first.h") >= 0 && dependencies[1].indexOf("second.h") >= 0,
			"native dependency scanning should follow recursive local includes");
		removeTree(root);
	}

	static function testPackageSourceModel():Void {
		var manifest = PackageManifest.parse("/tmp/example/haxeon.json", '{"package":{"name":"app"},"dependencies":{"git-dependency":{"git":"https://example.invalid/foo.git","rev":"main"},"path-dependency":{"path":"../path-dependency"}}}');
		expect(manifest.packageId.equals(new project.PackageId("app")), "package manifests should expose stable package identity");
		var git = manifest.dependencies.get("git-dependency"), path = manifest.dependencies.get("path-dependency");
		expect(git != null && path != null && PackageSourceTools.describe(git.source) == "git:https://example.invalid/foo.git@main",
			"git dependency metadata should remain a source declaration");
		expect(switch path.source {
			case project.PackageSource.Path(value): value == "../path-dependency";
			case _: false;
		}, "path dependency metadata should remain a path source declaration");
	}

	static function testResolverDelegatesAcquisition():Void {
		var root = temporaryDirectory("resolver"),
			app = Path.join([root, "app"]),
			foo = Path.join([root, "foo"]);
		writePackage(app, '{"package":{"name":"app"},"dependencies":{"foo":{"path":"../foo"}}}', []);
		writePackage(foo, '{"package":{"name":"foo"}}', []);
		var acquirer = new RecordingSourceAcquirer(),
			project = new PackageResolver(acquirer).resolve(Path.join([app, "haxeon.json"]));
		expect(acquirer.calls == 1 && project.packages.get("foo").source != null,
			"package resolution should delegate source acquisition and retain the source identity");
		removeTree(root);
	}

	static function action(id:String, dependencies:Array<ActionId>, description:String, invoke:Void->Int):ExecutionAction
		return new ExecutionAction(new ActionId(id), dependencies, [], [], description, Compiler(description, invoke));

	static function temporaryDirectory(name:String):String {
		var base = Sys.getEnv("TMPDIR");
		if (base == null || base == "")
			base = Sys.getEnv("TEMP");
		if (base == null || base == "")
			base = ".";
		var path = Path.join([base, 'haxeon-build-$name-${Std.int(Date.now().getTime())}']);
		FileSystem.createDirectory(path);
		return FileSystem.fullPath(path);
	}

	static function writePackage(root:String, manifest:String, files:Array<String>):Void {
		ensureDirectory(root);
		ensureDirectory(Path.join([root, "src"]));
		File.saveContent(Path.join([root, "haxeon.json"]), manifest + "\n");
		for (path in files) {
			var absolute = Path.join([root, path]);
			ensureDirectory(Path.directory(absolute));
			File.saveContent(absolute, path + "\n");
		}
	}

	static function ensureDirectory(path:String):Void {
		if (path == null || path == "" || path == "." || FileSystem.exists(path))
			return;
		ensureDirectory(Path.directory(path));
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}

	static function expectThrows(invoke:Void->Void, message:String):Void {
		var threw = false;
		try {
			invoke();
		} catch (_:Dynamic) {
			threw = true;
		}
		expect(threw, message);
	}

	static function removeTree(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (!FileSystem.isDirectory(path)) {
			FileSystem.deleteFile(path);
			return;
		}
		for (entry in FileSystem.readDirectory(path))
			removeTree(Path.join([path, entry]));
		FileSystem.deleteDirectory(path);
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}

class RecordingSourceAcquirer implements SourceAcquirer {
	public var calls:Int = 0;
	final delegate:PathSourceAcquirer;

	public function new() {
		delegate = new PathSourceAcquirer();
	}

	public function acquire(source:project.PackageSource, ownerRoot:String, packageId:project.PackageId):String {
		calls++;
		return delegate.acquire(source, ownerRoot, packageId);
	}
}
