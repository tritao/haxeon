import build.Artifact;
import build.ArtifactId;
import build.BuildEnvironment;
import build.BuildEnvironment.BuildProfile;
import build.BuildEnvironment.ToolchainInfo;
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
import build.execution.ExecutionBackend.ExecutionBackendFactory;
import build.execution.Executor;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import build.native.NativeDependencyScanner;
import haxe.io.Path;
import project.ProjectDiscovery;
import project.PackageManifest;
import project.PackageSourceTools;
import project.PackageResolver;
import project.PackageLockfile;
import project.PackageLockfile.PackageLockEntry;
import project.PathSourceAcquirer;
import project.HaxelibSourceAcquirer;
import project.RegistrySourceAcquirer;
import project.RegistryPublisher;
import haxe.crypto.Sha256;
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
		testExecutorBackendSelection();
		testIndependentProcessActionsRunConcurrently();
		#if (target.threaded && !eval)
		testIndependentActionsRunConcurrently();
		#end
		testFingerprintsAndSkipping();
		testArtifactCache();
		testTargetsAndToolchains();
		testProjectDiscovery();
		testPackageSourceModel();
		testPackageCompatibility();
		testHaxelibAdapter();
		testRegistryAdapter();
		testRegistryPublisher();
		testResolverDelegatesAcquisition();
		testLockfileRoundTrip();
		testNativeDependencyScanning();
		Sys.println("PASS: build model, executor, fingerprints, target toolchains, demand-driven native outputs, and package discovery");
	}

	static function testTargetsAndToolchains():Void {
		var windows = Target.parse("windows-x86_64-msvc"),
			linux = Target.parse("linux-x86_64-gnu"),
			mac = Target.parse("macos-aarch64"),
			android = Target.parse("android-aarch64"),
			wasm = Target.parse("wasm32");
		expect(windows.toString() == "windows-x86_64-msvc", "Windows target triples should be canonical");
		expect(linux.toString() == "linux-x86_64-gnu", "Linux target triples should be canonical");
		expect(mac.toString() == "macos-arm64"
			&& mac.equals(Target.parse("macos-arm64-darwin")), "Apple targets should accept architecture aliases");
		expect(android.isAndroid() && android.toString() == "android-arm64", "Android targets should have a stable short identity");
		expect(wasm.isWasm() && wasm.toString() == "wasm32", "Wasm should be a first-class target");
		var androidToolchain = ToolchainInfo.detect(android),
			wasmToolchain = ToolchainInfo.detect(wasm);
		expect(androidToolchain.targetTriple == "aarch64-linux-android21"
			&& androidToolchain.compileFlags[0] == "--target=aarch64-linux-android21",
			"Android toolchains should centralize their ABI and compiler flags");
		expect(wasmToolchain.targetTriple == "wasm32-wasi" && wasmToolchain.compileFlags[0] == "--target=wasm32-wasi",
			"Wasm toolchains should centralize their target flags");
		var root = temporaryDirectory("target-layout"),
			environment = new BuildEnvironment(root, Path.join([root, "build"]), BuildProfile.Debug, android),
			layout = new TargetLayout(environment);
		expect(layout.targetDirectory() == "android-arm64" && layout.packageRoot("foo").indexOf("android-arm64") >= 0,
			"non-host artifacts should be isolated by target");
		removeTree(root);
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

	static function testExecutorBackendSelection():Void {
		var root = temporaryDirectory("executor-backend"),
			environment = new BuildEnvironment(root, Path.join([root, "build"])),
			backend = ExecutionBackendFactory.create(environment, 1, _ -> {});
		expect(backend.name() == "native", "the native executor should be selected behind a replaceable backend boundary");
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

	static function testArtifactCache():Void {
		var cache = temporaryDirectory("artifact-cache-store"),
			firstRoot = temporaryDirectory("artifact-cache-first"),
			secondRoot = temporaryDirectory("artifact-cache-second"),
			firstSource = Path.join([firstRoot, "source.txt"]),
			firstOutput = Path.join([firstRoot, "output.txt"]),
			secondSource = Path.join([secondRoot, "source.txt"]),
			secondOutput = Path.join([secondRoot, "output.txt"]);
		File.saveContent(firstSource, "same input\n");
		File.saveContent(secondSource, "same input\n");
		if (Sys.systemName() != "Windows" && Sys.command("chmod", ["751", firstSource]) != 0)
			throw "Could not prepare executable artifact-cache fixture";
		Sys.putEnv("HAXEON_ARTIFACT_CACHE", cache);
		var firstAction = new ExecutionAction(new ActionId("portable-copy"), [], [firstSource], [firstOutput], "portable copy",
			Process("sh", ["-c", 'cp "$firstSource" "$firstOutput"'], firstRoot, new Map())),
			secondAction = new ExecutionAction(new ActionId("portable-copy"), [], [secondSource], [secondOutput], "portable copy",
				Process("sh", ["-c", 'cp "$secondSource" "$secondOutput"'], secondRoot, new Map())),
			firstEnvironment = new BuildEnvironment(firstRoot, Path.join([firstRoot, "build"])),
			secondEnvironment = new BuildEnvironment(secondRoot, Path.join([secondRoot, "build"]));
		var firstResult = new Executor(firstEnvironment, 1, _ -> {}).execute(new ExecutionPlan([firstAction]));
		var secondResult = new Executor(secondEnvironment, 1, _ -> {}).execute(new ExecutionPlan([secondAction]));
		expect(firstResult.exitCode == 0
			&& secondResult.exitCode == 0
			&& secondResult.actions[0].skipped
			&& File.getContent(secondOutput) == "same input\n"
			&& (Sys.systemName() == "Windows" || (FileSystem.stat(secondOutput).mode & 0x40) != 0),
			"portable process artifacts should restore from the global cache with executable permissions");
		removeTree(cache);
		removeTree(firstRoot);
		removeTree(secondRoot);
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
			execution = PlanLowerer.lower(plan,
				new LoweringContext(environment, null, project, new TargetLayout(environment).hashLinkModulePath("main"), project.root)),
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
		var wasmDiagnostic:Null<String> = null;
		try {
			BuildPlanner.project(project, BuildIntent.Build, Target.parse("wasm32"), NativeArtifactDemand.Shared);
		} catch (error:Dynamic) {
			wasmDiagnostic = Std.string(error);
		}
		expect(wasmDiagnostic != null
			&& wasmDiagnostic.indexOf("foo cannot be built for wasm32") >= 0
			&& wasmDiagnostic.indexOf("no wasm32 provider is available") >= 0,
			"unsupported native Wasm combinations should fail with a planning diagnostic");

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
		var manifest = PackageManifest.parse("/tmp/example/haxeon.json",
			'{"package":{"name":"app"},"dependencies":{"git-dependency":{"git":"https://example.invalid/foo.git","rev":"main"},"path-dependency":{"path":"../path-dependency"}}}');
		expect(manifest.packageId.equals(new project.PackageId("app")), "package manifests should expose stable package identity");
		var git = manifest.dependencies.get("git-dependency"),
			path = manifest.dependencies.get("path-dependency");
		expect(git != null && path != null && PackageSourceTools.describe(git.source) == "git:https://example.invalid/foo.git@main",
			"git dependency metadata should remain a source declaration");
		expect(switch path.source {
			case project.PackageSource.Path(value): value == "../path-dependency";
			case _: false;
		}, "path dependency metadata should remain a path source declaration");
	}

	static function testPackageCompatibility():Void {
		var manifest = PackageManifest.parse("/tmp/compatible/haxeon.json",
			'{"package":{"name":"compatible"},"compatibility":{"haxeon":">=0.3","targets":["host"],"runtimeAbi":"2"}}');
		manifest.compatibility.validate("compatible", Target.detectHost());
		var rejected:Null<String> = null;
		try {
			manifest.compatibility.validate("compatible", Target.parse("wasm32"));
		} catch (error:Dynamic) {
			rejected = Std.string(error);
		}
		expect(rejected != null && rejected.indexOf("does not support target wasm32") >= 0,
			"package compatibility should reject unsupported targets before compilation");
		var badVersion = PackageManifest.parse("/tmp/incompatible/haxeon.json", '{"package":{"name":"incompatible"},"compatibility":{"haxeon":">=0.4"}}');
		rejected = null;
		try {
			badVersion.compatibility.validate("incompatible", Target.detectHost());
		} catch (error:Dynamic) {
			rejected = Std.string(error);
		}
		expect(rejected != null
			&& rejected.indexOf("requires Haxeon") >= 0, "package compatibility should reject incompatible Haxeon versions");
	}

	static function testHaxelibAdapter():Void {
		var root = temporaryDirectory("haxelib"),
			app = Path.join([root, "app"]),
			cache = Path.join([root, "cache"]),
			foo = Path.join([cache, "foo", "1.0.0"]);
		writePackage(app, '{"package":{"name":"app"},"dependencies":{"foo":{"haxelib":"foo","version":"1.0.0"}}}', []);
		ensureDirectory(Path.join([foo, "src"]));
		File.saveContent(Path.join([foo, "haxelib.json"]), '{"name":"foo","version":"1.0.0","classPath":"src","dependencies":{}}\n');
		File.saveContent(Path.join([foo, "src", "Foo.hx"]), "class Foo {}\n");
		var project = new PackageResolver(new HaxelibSourceAcquirer(cache)).resolve(Path.join([app, "haxeon.json"]));
		expect(project.packages.get("foo").source != null && FileSystem.exists(Path.join([foo, "haxeon.json"])),
			"Haxelib metadata should be adapted into a cached Haxeon manifest");
		var bad = Path.join([cache, "bad", "1.0.0"]);
		ensureDirectory(bad);
		File.saveContent(Path.join([bad, "haxelib.json"]), '{"name":"bad","version":"1.0.0","extraParams":["--macro","bad()"]}\n');
		var badApp = Path.join([root, "bad-app"]);
		writePackage(badApp, '{"package":{"name":"bad-app"},"dependencies":{"bad":{"haxelib":"bad","version":"1.0.0"}}}', []);
		expectThrows(() -> new PackageResolver(new HaxelibSourceAcquirer(cache)).resolve(Path.join([badApp, "haxeon.json"])),
			"unsupported Haxelib compiler parameters should be diagnosed");
		removeTree(root);
	}

	static function testRegistryAdapter():Void {
		var root = temporaryDirectory("registry"),
			app = Path.join([root, "app"]),
			cache = Path.join([root, "cache"]),
			registryDirectory = Path.join([cache, Sha256.encode("local")]),
			foo = Path.join([registryDirectory, "foo", "1.1.0"]),
			checksum = "release-checksum";
		writePackage(app, '{"package":{"name":"app"},"dependencies":{"foo":{"registry":"local","version":"^1.0"}}}', []);
		ensureDirectory(foo);
		File.saveContent(Path.join([foo, "haxeon.json"]), '{"package":{"name":"foo"},"sourceRoots":["src"]}\n');
		ensureDirectory(Path.join([foo, "src"]));
		File.saveContent(Path.join([foo, "src", "Foo.hx"]), "class Foo {}\n");
		File.saveContent(Path.join([foo, ".haxeon-checksum"]), checksum + "\n");
		ensureDirectory(registryDirectory);
		File.saveContent(Path.join([registryDirectory, "index.json"]),
			'{"version":1,"packages":{"foo":{"versions":[{"version":"1.2.0","checksum":"yanked","yanked":true},{"version":"1.1.0","checksum":"$checksum","targets":["host"]},{"version":"0.9.0","checksum":"old"}]}}}\n');
		var resolver = new PackageResolver(new RegistrySourceAcquirer(cache)),
			project = resolver.resolve(Path.join([app, "haxeon.json"])),
			entry = project.lockfile.get("foo");
		expect(entry != null && entry.resolvedRevision == "1.1.0" && entry.checksum == checksum,
			"registry resolution should select the highest non-yanked SemVer release and lock its checksum");
		var locked = resolver.resolve(Path.join([app, "haxeon.json"]), project.lockfile, true);
		expect(locked.packages.get("foo").source != null, "locked registry releases should resolve through the same adapter");
		File.saveContent(Path.join([foo, ".haxeon-checksum"]), "tampered\n");
		expectThrows(() -> resolver.resolve(Path.join([app, "haxeon.json"])), "registry source checksums should be verified on every use");
		removeTree(root);
	}

	static function testRegistryPublisher():Void {
		var root = temporaryDirectory("registry-publish"),
			packageRoot = Path.join([root, "package"]),
			registryRoot = Path.join([root, "registry"]);
		writePackage(packageRoot, '{"package":{"name":"published"},"sourceRoots":["src"],"compatibility":{"targets":["host"]}}', ["src/Published.hx"]);
		var checksum = RegistryPublisher.publish(Path.join([packageRoot, "haxeon.json"]), "local", "1.0.0", registryRoot),
			destination = Path.join([registryRoot, Sha256.encode("local"), "published", "1.0.0"]);
		expect(checksum.length == 64 && FileSystem.exists(Path.join([destination, ".haxeon-checksum"])),
			"registry publication should create a checksum-marked immutable release");
		expectThrows(() -> RegistryPublisher.publish(Path.join([packageRoot, "haxeon.json"]), "local", "1.0.0", registryRoot),
			"registry publication should reject replacing an existing version");
		removeTree(root);
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

	static function testLockfileRoundTrip():Void {
		var lock = new PackageLockfile([
			new PackageLockEntry(new project.PackageId("app"), project.PackageSource.Path("."), null, null, [new project.PackageId("foo")]),
			new PackageLockEntry(new project.PackageId("foo"), project.PackageSource.Git("https://example.invalid/foo.git", "main"),
				"0123456789012345678901234567890123456789")
		]), parsed = PackageLockfile.parse("haxeon.lock", lock.toJson());
		lock.validateGraph(parsed);
		expect(parsed.get("foo").resolvedRevision == "0123456789012345678901234567890123456789"
			&& switch parsed.get("foo").resolvedSource() {
				case project.PackageSource.Git(_, revision): revision == parsed.get("foo").resolvedRevision;
				case _: false;
			}, "lockfiles should round-trip immutable Git revisions and dependency edges");
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

	public function acquire(source:project.PackageSource, ownerRoot:String, packageId:project.PackageId):project.AcquiredSource {
		calls++;
		return delegate.acquire(source, ownerRoot, packageId);
	}
}
