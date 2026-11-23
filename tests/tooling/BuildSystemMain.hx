import build.Artifact;
import build.ArtifactId;
import build.BuildEnvironment;
import build.BuildEnvironment.BuildProfile;
import build.BuildEnvironment.ToolchainInfo;
import build.BuildIntent;
import build.BuildPlan;
import build.BuildPlanner;
import build.BuildSession;
import build.HaxeonProjectBuild;
import build.NativeArtifactDemand.NativeArtifactDemand;
import build.Target;
import build.TargetLayout;
import build.WorkspaceBuild;
import build.WorkspaceBuild.LoweredWorkspace;
import build.WorkspaceBuild.LoweredWorkspaceProject;
import build.execution.ActionFingerprint;
import build.execution.ActionId;
import build.execution.ActionResult;
import build.execution.ArtifactCache;
import build.execution.CompilerClient;
import build.execution.ContentDigestCache;
import build.execution.DigestStore;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.execution.ExecutionBackend.ExecutionBackendFactory;
import build.execution.ExecutionPlan;
import build.execution.Executor;
import build.execution.JobServer;
import build.execution.OutputCapture;
import build.execution.ProcessRunner;
import build.lowering.LoweringContext;
import build.lowering.PlanLowerer;
import build.native.NativeDependencyScanner;
import build.native.NativeToolchain;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import haxeon.io.FileTree;
import project.CompilerInputs;
import project.FfiManifest.FfiImportManifest;
import project.HaxelibSourceAcquirer;
import project.PackageLockfile;
import project.PackageLockfile.PackageLockEntry;
import project.PackageManifest;
import project.PackageManifest.InstrumentManifest;
import project.PackageResolver;
import project.PackageSourceCodec;
import project.PackageSourceTools;
import project.PathSourceAcquirer;
import project.ProjectDiscovery;
import project.ProjectSourceAcquirer;
import project.RegistryIndex;
import project.RegistryPublisher;
import project.RegistrySourceAcquirer;
import project.SourceAcquirer;
import sys.FileSystem;
import sys.io.File;
import tools.DirectoryWatcher;
import tools.WatchEventLines;
import tools.WatchEvents;
import tools.WatchRun;
#if (target.threaded && !eval)
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

class BuildSystemMain {
	/** The SDK the builds lower against: the test driver's (`HAXEON_SDK`), else the checkout's. */
	static function sdk():String {
		var current = build.HaxeonSdk.current();
		return current != null ? current : build.HaxeonSdk.ofCheckout(Sys.getCwd());
	}

	static function main():Void {
		// testWatchBuildsSavesMadeDuringABuild launches this program as its watched app.
		var args = Sys.args();
		if (args.length == 2 && args[0] == "--watch-test-app") {
			Sys.sleep(Std.parseFloat(args[1]));
			return;
		}
		testArtifactAndPlanDeterminism();
		testExecutorOrderingAndFailure();
		testExecutorBackendSelection();
		testLaunchEnvironmentCopies();
		testIndependentProcessActionsRunConcurrently();
		#if (target.threaded && !eval)
		testIndependentActionsRunConcurrently();
		testDependentStartsWithoutWaitingForSlowSibling();
		testCompilerConcurrencyLimit();
		testJobServerTokens();
		testExecutorSharesJobServerTokens();
		#end
		testFingerprintsAndSkipping();
		testPersistentDigestCache();
		testDigestStore();
		testSharedDigestsAcrossExecutions();
		testWorkerVersionMemo();
		testWatchChangeClassification();
		testWatchSnapshot();
		testWatchEventsFile();
		testDirectoryWatcher();
		#if (target.threaded && !eval)
		testWatchBuildsSavesMadeDuringABuild();
		#end
		testArtifactCache();
		testDelegatedNativeInvalidation();
		testCMakeLibraryOutputs();
		testMissingDeclaredOutputs();
		testDirectoryOutputs();
		testTargetsAndToolchains();
		testProjectDiscovery();
		testFfiProjectIntegration();
		testCompilerInputs();
		testOfflineGitResolution();
		testPackageSourceModel();
		testPackageCompatibility();
		testHaxelibAdapter();
		testRegistryAdapter();
		testDefaultRegistryShorthand();
		testRegistryPublisher();
		testLiveRegistry();
		testRegistryRepick();
		testRegistryPatch();
		testResolverDelegatesAcquisition();
		testAlternateRootManifest();
		testLockfileRoundTrip();
		testNativeDependencyScanning();
		Sys.println("PASS: build model, executor, fingerprints, target toolchains, demand-driven native outputs, and package discovery");
	}

	static function testCMakeLibraryOutputs():Void {
		var root = temporaryDirectory("cmake-libraries");
		var manifest = '{"version":1,"package":{"name":"aggregate"},"entry":"Main","sourceRoots":["src"],'
			+ '"native":{"cmake":{"source":"native","target":"aggregate_native","libraries":["alpha","beta"]}}}';
		writePackage(root, manifest, ["src/Main.hx", "native/CMakeLists.txt"]);
		var project = ProjectDiscovery.discover(Path.join([root, "haxeon.json"]));
		for (triple in ["linux-x86_64-gnu", "macos-arm64", "windows-x86_64-msvc"])
			for (shared in [false, true]) {
				var target = Target.parse(triple),
					environment = new BuildEnvironment(root, root + "/build", BuildProfile.Debug, target),
					context = new LoweringContext(environment, null, project, null, sdk(), null, false, shared),
					artifact = new Artifact(new ArtifactId("aggregate", ArtifactKind.NativeSharedLibrary, target)),
					lowered = build.native.NativeCMakeProvider.lowerPackage(project.rootPackage, [artifact], context),
					action = lowered.actions[1],
					prefix = target.os == build.Target.TargetOs.Windows ? "" : "lib";
				expect(action.outputs.length == 2, "aggregate must declare both library outputs");
				for (name in ["alpha", "beta"])
					expect([
						for (output in action.outputs)
							if (Path.withoutDirectory(output)
							== prefix + name + environment.toolchain.sharedLibrarySuffix) output
					].length == 1, "aggregate outputs must use the target's real library filenames");
				expect(action.outputs.join("\n").indexOf(".hdll") < 0,
					"aggregate outputs must not include a synthetic HDLL");
				for (output in action.outputs) {
					ensureDirectory(Path.directory(output));
					File.saveContent(output, "library");
				}
				expect(ActionFingerprint.outputsExist(action), "all declared outputs complete the action");
				FileSystem.deleteFile(action.outputs[1]);
				expect(!ActionFingerprint.outputsExist(action), "a missing secondary library invalidates the action");
			}
		for (declaration in [
			'"libraries":[]',
			'"libraries":["alpha","alpha"]',
			'"libraries":["../alpha"]',
			'"library":"alpha","libraries":["beta"]'
		])
			expectThrows(() -> PackageManifest.parse(root + "/invalid.json",
				'{"version":1,"native":{"cmake":{"source":"native","target":"aggregate",' + declaration + '}}}'),
				"invalid CMake library declarations must be rejected");
		FileTree.remove(root);
	}

	static function testMissingDeclaredOutputs():Void {
		var root = temporaryDirectory("missing-output"),
			environment = new BuildEnvironment(root, root + "/build"),
			output = root + "/absent.so",
			action = new ExecutionAction(new ActionId("native-cmake-build:missing"), [], [], [output], "missing output",
				Compiler("fixture", [], root, new Map(), () -> 0), true, true),
			result = new Executor(environment, 1, _ -> {}).execute(new ExecutionPlan([action]));
		expect(result.exitCode != 0 && result.actions[0].message.indexOf(output) >= 0,
			"a successful command missing a declared output must fail with its path");
		if (Sys.systemName() != "Windows") {
			var ran = false,
				process = new ExecutionAction(new ActionId("missing-process-output"), [], [], [output],
					"missing process output",
					Process("sh", [
						"-c",
						"exit 0"
					], root, new Map())),
				dependent = new ExecutionAction(new ActionId("dependent"), [process.id], [], [], "dependent",
					Compiler("fixture", [], root, new Map(),
					() -> {
						ran = true;
						return 0;
					})), failure = new Executor(environment, 2,
						_ -> {}).execute(new ExecutionPlan([process, dependent]));
			expect(failure.exitCode != 0 && !ran,
				"a missing process output must block dependents in either executor backend");
		}
		FileTree.remove(root);
	}

	static function testDirectoryOutputs():Void {
		var root = temporaryDirectory("directory-output"),
			directory = root + "/projection",
			environment = new BuildEnvironment(root, root + "/build"),
			invocations = 0,
			action = new ExecutionAction(new ActionId("projection-fixture"), [], [], [directory], "directory output",
				Compiler("fixture", [], root, new Map(), () -> {
					invocations++;
					ensureDirectory(directory);
					return 0;
				}), true, false, false, [directory]),
					plan = new ExecutionPlan([action]);
		expect(!ActionFingerprint.outputsExist(action), "a missing directory output invalidates the action");
		expect(new Executor(environment, 1, _ -> {}).execute(plan).exitCode == 0,
			"declared directory outputs must pass execution validation");
		expect(ActionFingerprint.outputsExist(action), "an existing declared directory completes the action");
		expect(new Executor(environment, 1, _ -> {}).execute(plan).exitCode == 0 && invocations == 1,
			"complete directory outputs permit project-local skipping");
		var fileAction = new ExecutionAction(action.id, [], [], [directory], action.description, action.action);
		expect(!ActionFingerprint.outputsExist(fileAction), "a directory cannot satisfy a file output");
		expect(ActionFingerprint.compute(action, environment.buildRoot, environment.target.toString(),
			[]) != ActionFingerprint.compute(fileAction, environment.buildRoot, environment.target.toString(), []),
			"output kinds participate in the fingerprint");
		var processAction = new ExecutionAction(new ActionId("projection-process"), [], [], [directory],
			"directory output",
			Process("fixture", [], root, new Map()), true, false, false, [directory]);
		expect(!ArtifactCache.isShareable(processAction),
			"directory outputs are excluded from the portable file artifact cache");
		FileTree.remove(directory);
		File.saveContent(directory, "wrong kind");
		expect(!ActionFingerprint.outputsExist(action), "a file cannot satisfy a directory output");
		var wrongKind = new ExecutionAction(new ActionId("wrong-output-kind"), [], [], [directory], "directory output",
			Compiler("fixture", [], root, new Map(), () -> 0), true, true, false, [directory]);
		expect(new Executor(environment, 1, _ -> {}).execute(new ExecutionPlan([wrongKind])).exitCode != 0,
			"a successful process with the wrong output kind fails validation");
		expectThrows(() -> new ExecutionAction(action.id, [], [], [], "invalid", action.action, true, false, false,
			[directory]),
			"directory outputs must also appear in declared outputs");
		FileTree.remove(root);
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
		expect(android.isAndroid() && android.toString() == "android-arm64",
			"Android targets should have a stable short identity");
		expect(wasm.isWasm() && wasm.toString() == "wasm32", "Wasm should be a first-class target");
		var wasm64Error:Null<String> = null;
		try {
			Target.parse("wasm64");
		} catch (error:Dynamic) {
			wasm64Error = Std.string(error);
		}
		expect(wasm64Error != null && wasm64Error.indexOf("not implemented") >= 0,
			"wasm64 should be rejected as not implemented");
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
		var msvcToolchain = new NativeToolchain(new BuildEnvironment(root, Path.join([root, "build-msvc"]),
			BuildProfile.Debug, windows)),
			gnuWindows = Target.parse("windows-x86_64-gnu"),
			gnuToolchain = new NativeToolchain(new BuildEnvironment(root, Path.join([root, "build-gnu"]),
				BuildProfile.Debug, gnuWindows)),
			msvcCompile = msvcToolchain.compileArguments("fixture.cpp", "fixture.obj", [], "c++20"),
			gnuCompile = gnuToolchain.compileArguments("fixture.cpp", "fixture.o", [], "c++20"),
			msvcLink = msvcToolchain.sharedArguments("fixture.dll", ["fixture.obj"], ["foo.lib"]),
			gnuLink = gnuToolchain.sharedArguments("fixture.dll", ["fixture.o"], ["libfoo.dll.a"]);
		expect(msvcCompile.indexOf("/std:c++20") >= 0 && msvcLink.indexOf("/LD") >= 0
			&& msvcLink.indexOf("foo.lib") >= 0,
			"MSVC C++ toolchains should use cl standard, DLL, and import-library arguments");
		expect(gnuCompile.indexOf("-std=c++20") >= 0 && gnuLink.indexOf("-shared") >= 0
			&& gnuLink.indexOf("libfoo.dll.a") >= 0,
			"MinGW C++ toolchains should use GNU standard, DLL, and import-library arguments");
		testLinuxNativeInstrumentation(root);
		FileTree.remove(root);
	}

	/** Linux instruments the sources in the native scope with the compiler's flags and links the hooks into each module. */
	static function testLinuxNativeInstrumentation(root:String):Void {
		var linux = Target.parse("linux-x86_64-gnu"),
			scope = new InstrumentManifest(null, null, ["native/**"], ["native/vendor/skipped.c"]);
		function toolchain(clang:Bool, ?instrument:InstrumentManifest, ?home:String):NativeToolchain {
			var info = new ToolchainInfo("cc", "c++", "ar", ".o", ".a", ".so", null, null, null, null, null, clang);
			return new NativeToolchain(new BuildEnvironment(root, Path.join([root, "build-linux"]), BuildProfile.Debug,
				linux, info, instrument), home);
		}
		var home = sdk(),
			clang = toolchain(true, scope, home),
			gcc = toolchain(false, scope, home),
			plain = toolchain(true, null, home),
			noHome = toolchain(true, scope),
			clangCompile = clang.compileArguments("native/a.c", "a.o", [], null, root),
			gccCompile = gcc.compileArguments("native/a.c", "a.o", [], null, root);
		expect(clang.instrumenting() && !plain.instrumenting() && !noHome.instrumenting(),
			"Linux instruments only the instrumented flavor, and only when the hooks can be found");
		expect(clangCompile.indexOf("-finstrument-functions-after-inlining") >= 0
			&& clangCompile.indexOf("-finstrument-functions") < 0,
			"Clang should leave out functions it inlines");
		expect(gccCompile.indexOf("-finstrument-functions") >= 0
			&& gccCompile.indexOf("-finstrument-functions-exclude-file-list=/usr/include,/c++/") >= 0
			&& gccCompile.indexOf("-finstrument-functions-after-inlining") < 0,
			"GCC should skip functions defined in system headers");
		expect(clang.compileArguments("native/vendor/skipped.c", "s.o", [], null,
			root).indexOf("-finstrument-functions-after-inlining") < 0
			&& clang.compileArguments("other/b.c", "b.o", [], null,
			root).indexOf("-finstrument-functions-after-inlining") < 0,
			"sources outside the native scope, or excluded from it, are left alone");
		expect(clang.compileArguments("native/a.c", "a.o", []).indexOf("-finstrument-functions-after-inlining") < 0,
			"a source without an instrument root is left alone");
		var hooks = Path.join([build.HashLinkPath.libraryDirectory(home), "libhlprof_hooks.a"]),
			link = clang.sharedArguments("a.so", ["a.o"], ["-lm"]);
		expect(clang.instrumentHooks() == hooks && link.indexOf(hooks) > link.indexOf("a.o")
			&& link.indexOf(hooks) > link.indexOf("-lm"),
			"an instrumented module links the hooks after its objects and libraries");
		expect(!clang.writesDebugDatabase() && plain.sharedArguments("a.so", ["a.o"], ["-lm"]).indexOf(hooks) < 0,
			"a module is linked without a PDB, and without the hooks outside the instrumented flavor");
	}

	static function testArtifactAndPlanDeterminism():Void {
		var target = Target.detectHost(),
			library = new ArtifactId("foo", ArtifactKind.NativeStaticLibrary, target),
			module = new ArtifactId("app", ArtifactKind.HashLinkModule, target),
			first = new BuildPlan([module], [new Artifact(module, [library]), new Artifact(library)]),
			second = new BuildPlan([new ArtifactId("app", ArtifactKind.HashLinkModule, target)], [
				new Artifact(new ArtifactId("app", ArtifactKind.HashLinkModule, target),
					[new ArtifactId("foo", ArtifactKind.NativeStaticLibrary, target)]),
				new Artifact(new ArtifactId("foo", ArtifactKind.NativeStaticLibrary, target))
			]);
		expect(module.equals(new ArtifactId("app", ArtifactKind.HashLinkModule, target)),
			"artifact identity should be deterministic");
		expect(!module.equals(new ArtifactId("app", ArtifactKind.HashLinkModule, target, "debug")),
			"artifact variants should distinguish identity");
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
		expect(result.exitCode == 0 && result.actions.length == 3,
			"independent actions should succeed before their dependent");
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
		var failed = new Executor(environment, 2, _ -> {}).execute(new ExecutionPlan([
			deepDependent,
			dependent,
			failure,
			independent
		]));
		expect(failed.exitCode == 37, "the original action exit status should propagate");
		expect(!dependentRan, "a failed dependency must prevent its consumer from executing");
		expect(!deepDependentRan, "failure should block every level of dependent actions");
		expect(independentRan, "actions unrelated to the failure should still be allowed to complete");
		FileTree.remove(root);
	}

	static function testExecutorBackendSelection():Void {
		var root = temporaryDirectory("executor-backend"),
			environment = new BuildEnvironment(root, Path.join([root, "build"])),
			backend = ExecutionBackendFactory.create(environment, 1, _ -> {});
		expect(backend.name() == "native",
			"the native executor should be selected behind a replaceable backend boundary");
		FileTree.remove(root);
	}

	/**
	 * A launch sets its process's variables in this process and restores the previous values. On HashLink for Windows,
	 * Sys.getEnv returns a String over the C runtime's copy, which Sys.putEnv frees, so a saved value must be a copy.
	 */
	static function testLaunchEnvironmentCopies():Void {
		var name = "HAXEON_TEST_LAUNCH_ENVIRONMENT";
		Sys.putEnv(name, "original value");
		var saved = ProcessRunner.environmentValue(name);
		Sys.putEnv(name, "a replacement long enough to need new storage for the variable");
		expect(saved == "original value",
			'a value read through ProcessRunner should outlive the variable being set again, got "$saved"');
		Sys.putEnv(name, "original value");
		// HashLink itself is a program that is sure to start on Windows, where cmd's quoting rules get in the way.
		var windows = Sys.systemName() == "Windows",
			status = ProcessRunner.run(windows ? Sys.executablePath() : "sh",
				windows ? ["--version"] : ["-c", "exit 0"], null, [name => "launch override"],
				false);
		expect(status == 0, 'the launch should succeed, got $status');
		expect(ProcessRunner.environmentValue(name) == "original value",
			"a launch should restore the variable it overrode");
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
			leftScript =
				'touch "$leftStarted"; for unused in 1 2 3 4 5 6 7 8 9 10; do if [ -f "$rightStarted" ]; then break; fi; sleep 0.05; done; test -f "$rightStarted" || exit 17; touch "$leftDone"',
			rightScript =
				'touch "$rightStarted"; for unused in 1 2 3 4 5 6 7 8 9 10; do if [ -f "$leftStarted" ]; then break; fi; sleep 0.05; done; test -f "$leftStarted" || exit 19; touch "$rightDone"',
			left = new ExecutionAction(new ActionId("process-left"), [], [], [leftDone], "concurrent process left",
				Process("sh", [
					"-c",
					leftScript
				], root, new Map())),
			right = new ExecutionAction(new ActionId("process-right"), [], [], [rightDone], "concurrent process right",
				Process("sh", [
					"-c",
					rightScript
				], root, new Map())),
			result = new Executor(environment, 2, _ -> {}).execute(new ExecutionPlan([left, right]));
		expect(result.exitCode == 0 && FileSystem.exists(leftDone) && FileSystem.exists(rightDone),
			'independent external process actions should overlap on host targets (exit ${result.exitCode}, action statuses ${[for (action in result.actions) action.exitCode].join(",")}, '
			+ 'markers: left=${FileSystem.exists(leftDone)}, right=${FileSystem.exists(rightDone)})');
		FileTree.remove(root);
	}

	#if (target.threaded && !eval)
	static function testIndependentActionsRunConcurrently():Void {
		var root = temporaryDirectory("parallel"),
			environment = new BuildEnvironment(root, Path.join([root, "build"])),
			mutex = new Mutex(),
			active = 0,
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
		FileTree.remove(root);
	}

	static function testDependentStartsWithoutWaitingForSlowSibling():Void {
		var root = temporaryDirectory("work-queue"),
			environment = new BuildEnvironment(root, Path.join([root, "build"])),
			slowFinished = false,
			slowFinishedWhenDependentStarted = true,
			slow = action("slow", [], "slow", () -> {
				Sys.sleep(0.4);
				slowFinished = true;
				0;
			}),
				quick = action("quick", [], "quick", () -> {
			Sys.sleep(0.02);
			0;
		}),
			dependent = action("dependent", [quick.id], "dependent", () -> {
			slowFinishedWhenDependentStarted = slowFinished;
			0;
		}),
			result = new Executor(environment, 2, _ -> {}).execute(new ExecutionPlan([slow, quick, dependent]));
		expect(result.exitCode == 0 && result.actions.length == 3, "the work queue should finish every action");
		expect(!slowFinishedWhenDependentStarted,
			"a ready dependent should start while a slow sibling still runs, not wait for a wave to end");
		FileTree.remove(root);
	}

	static function testJobServerTokens():Void {
		if (Sys.systemName() == "Windows")
			return;
		var root = temporaryDirectory("jobserver"),
			server = JobServer.start(root, 2);
		expect(server != null, "a job server should start on hosts with FIFOs");
		expect(server.makeFlags.indexOf("--jobserver-auth=fifo:" + server.path) >= 0,
			"clients find the pool through MAKEFLAGS");
		expect(server.acquire() && server.acquire(), "a pool of two tokens hands out two tokens");
		var third = false, finished = new Lock();
		Thread.create(function() {
			third = server.acquire();
			finished.release();
		});
		expect(!finished.wait(0.4), "a third acquire must block while both tokens are held");
		server.release();
		expect(finished.wait(5) && third, "releasing a token should wake the blocked acquire");
		server.release();
		server.release();
		expect(server.acquire() && server.acquire(), "returned tokens are usable again");
		server.stop();
		expect(!FileSystem.exists(server.path), "stopping the server removes its FIFO");
		FileTree.remove(root);
	}

	static function testExecutorSharesJobServerTokens():Void {
		if (Sys.systemName() == "Windows")
			return;
		var root = temporaryDirectory("jobserver-executor"),
			environment = new BuildEnvironment(root, Path.join([
				root,
				"build"
			])),
			server = JobServer.start(root, 2),
			mutex = new Mutex(),
			active = 0,
			peakActive = 0,
			invoke = function():Int {
				mutex.acquire();
				active++;
				if (active > peakActive)
					peakActive = active;
				mutex.release();
				Sys.sleep(0.1);
				mutex.acquire();
				active--;
				mutex.release();
				return 0;
			}, executor = new Executor(environment, 4, _ -> {});
		executor.jobServer = server;
		var result = executor.execute(new ExecutionPlan([
			action("token-a", [], "token A", invoke),
			action("token-b", [], "token B", invoke),
			action("token-c", [], "token C", invoke),
			action("token-d", [], "token D", invoke)
		]));
		server.stop();
		expect(result.exitCode == 0 && result.actions.length == 4, "actions sharing a job server should all complete");
		expect(peakActive == 2, 'two tokens should cap four workers at two running actions, saw $peakActive');
		FileTree.remove(root);
	}

	static function testCompilerConcurrencyLimit():Void {
		var root = temporaryDirectory("compiler-limit"),
			environment = new BuildEnvironment(root, Path.join([
				root,
				"build"
			])),
			mutex = new Mutex(),
			active = 0,
			peakActive = 0,
			invoke = function():Int {
				mutex.acquire();
				active++;
				if (active > peakActive)
					peakActive = active;
				mutex.release();
				Sys.sleep(0.05);
				mutex.acquire();
				active--;
				mutex.release();
				return 0;
			}, executor = new Executor(environment, 3, _ -> {});
		executor.maxConcurrentCompilers = 1;
		var result = executor.execute(new ExecutionPlan([
			action("limit-a", [], "limit A", invoke),
			action("limit-b", [], "limit B", invoke),
			action("limit-c", [], "limit C", invoke)
		]));
		expect(result.exitCode == 0 && result.actions.length == 3, "limited compiler actions should all still run");
		expect(peakActive == 1, "maxConcurrentCompilers should serialize compiler actions even with idle workers");
		FileTree.remove(root);
	}
	#end

	static function testFingerprintsAndSkipping():Void {
		expect(build.execution.ContentDigest.makeHex(haxe.io.Bytes.ofString(""))
			== "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
			"empty content digest must retain the canonical lowercase SHA-256 identity");
		expect(build.execution.ContentDigest.makeHex(haxe.io.Bytes.ofString("abc"))
			== "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
			"content digest must preserve the published SHA-256 test vector");
		var root = temporaryDirectory("fingerprints"),
			buildRoot = Path.join([root, "build"]),
			source = Path.join([root, "source.c"]),
			includeDirectory = Path.join([root, "include"]),
			header = Path.join([includeDirectory, "first.h"]),
			output = Path.join([root, "artifact"]);
		FileSystem.createDirectory(includeDirectory);
		File.saveContent(source, "int value(void) { return 42; }\n");
		File.saveContent(header, "#define VALUE 42\n");
		var generatedDirectory = Path.join([includeDirectory, "build"]),
			toolsDirectory = Path.join([includeDirectory, ".tools"]);
		FileSystem.createDirectory(generatedDirectory);
		FileSystem.createDirectory(toolsDirectory);
		File.saveContent(Path.join([generatedDirectory, "generated.o"]), "first generated output\n");
		File.saveContent(Path.join([toolsDirectory, "tool.bin"]), "first installed tool\n");
		File.saveContent(output, "artifact\n");
		var digests = new build.execution.ContentDigestCache();
		expect(digests.file(source) == Sha256.make(File.getBytes(source)).toHex(),
			"memoized digests preserve SHA-256 identity");
		File.saveContent(source, "int value(void) { return 420; }\n");
		expect(digests.file(source) == Sha256.make(File.getBytes(source)).toHex(),
			"a changed tool/input must invalidate its memoized digest");

		var environment = new BuildEnvironment(root, buildRoot),
			actionValue = new ExecutionAction(new ActionId("compile-foo"), [], [source, includeDirectory], [output],
				"compile foo.c",
				Process("missing-tool-for-skip-test", [], root, new Map())),
			baseline = ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), []);
		ActionFingerprint.save(buildRoot, actionValue, baseline);
		var skipped = new Executor(environment, 1, _ -> {}).execute(new ExecutionPlan([actionValue]));
		expect(skipped.exitCode == 0 && skipped.actions[0].skipped,
			"unchanged action with existing outputs should be skipped");

		var changedArguments = new ExecutionAction(new ActionId("compile-foo"), [], [source, includeDirectory],
			[output], "compile foo.c",
			Process("missing-tool-for-skip-test", ["-O2"], root, new Map()));
		expect(ActionFingerprint.compute(changedArguments, buildRoot, environment.target.toString(), []) != baseline,
			"changed arguments should invalidate the action");
		expect(ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), ["dependency-a"])
			!= baseline,
			"changed dependencies should invalidate the action");
		File.saveContent(Path.join([generatedDirectory, "generated.o"]), "changed generated output\n");
		File.saveContent(Path.join([toolsDirectory, "tool.bin"]), "changed installed tool\n");
		expect(ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), []) == baseline,
			"generated build and tool directories should not invalidate source inputs");
		var renamedHeader = Path.join([includeDirectory, "renamed.h"]);
		FileSystem.rename(header, renamedHeader);
		expect(ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), []) != baseline,
			"renamed headers should invalidate a directory input");
		File.saveContent(source, "int value(void) { return 43; }\n");
		expect(ActionFingerprint.compute(actionValue, buildRoot, environment.target.toString(), []) != baseline,
			"changed source contents should invalidate the action");

		var compilerOutput = Path.join([root, "compiled.hl"]),
			compilerInvocations = 0,
			compilerAction = new ExecutionAction(new ActionId("compile-haxe"), [], [source], [compilerOutput],
				"compile Haxe",
				Compiler("haxeon-compiler", [
					"--target=hl",
					"--entry=Main"
				], root, new Map(), () -> {
					compilerInvocations++;
					File.saveContent(compilerOutput, "compiled\n");
					return 0;
				}));
		var firstCompile = new Executor(environment, 1, _ -> {}).execute(new ExecutionPlan([compilerAction])),
			secondCompile = new Executor(environment, 1, _ -> {}).execute(new ExecutionPlan([compilerAction]));
		expect(firstCompile.exitCode == 0 && !firstCompile.actions[0].skipped && secondCompile.exitCode == 0
			&& secondCompile.actions[0].skipped
			&& compilerInvocations == 1,
			"unchanged compiler actions with existing outputs should be skipped");
		var discovered = Path.join([root, "Discovered.hx"]), report = compilerOutput + ".inputs.json";
		File.saveContent(discovered, "first");
		var reportedAction = new ExecutionAction(new ActionId("compile-discovered"), [], [source], [
			compilerOutput,
			report
		], "compile discovered Haxe",
			Compiler("haxeon-compiler", ["--inputs-output=" + report], root, new Map(), () -> {
				compilerInvocations++;
				File.saveContent(compilerOutput, File.getContent(discovered));
				File.saveContent(report, haxe.Json.stringify([
					["Discovered", discovered, build.execution.ContentDigest.makeHex(File.getBytes(discovered))],
					["Generated", "ffi/Generated.hx", "generated digest"]
				]));
				return 0;
			}));
		function executeReported() return new Executor(environment, 1,
			_ -> {}).execute(new ExecutionPlan([reportedAction]));
		expect(executeReported().exitCode == 0 && executeReported().actions[0].skipped,
			"discovered dependencies are cached after the first compile");
		File.saveContent(discovered, "second");
		expect(!executeReported().actions[0].skipped && File.getContent(compilerOutput) == "second",
			"editing an unlisted loaded module rebuilds the binary");
		expect(executeReported().actions[0].skipped, "rebuilt discovered inputs become clean");
		var compiledFingerprint = ActionFingerprint.compute(reportedAction, buildRoot, environment.target.toString(),
			[], null, true);
		File.saveContent(discovered, "saved during compilation");
		expect(ActionFingerprint.compute(reportedAction, buildRoot, environment.target.toString(), [])
			!= compiledFingerprint,
			"an edit made after the compiler read a module must not be saved as clean");
		FileSystem.deleteFile(report);
		expect(!executeReported().actions[0].skipped, "missing dependency reports force compilation");
		FileTree.remove(root);
	}

	static function testPersistentDigestCache():Void {
		var root = temporaryDirectory("persistent-digests"),
			source = Path.join([root, "input.txt"]);
		File.saveContent(source, "first contents
");
		// A store of its own: the clock this test moves would otherwise put its digests in the user's.
		var store = new DigestStore(Path.join([root, "content-digests"])),
			cache = new ContentDigestCache(true, store),
			now = Sys.time();
		cache.clock = () -> now;
		var first = cache.file(source);
		expect(first == Sha256.make(File.getBytes(source)).toHex() && cache.hashes == 1,
			"a persistent cache hashes a file once");
		// Just written, so its timestamps are within the margin of the hash: the entry is racily clean and must not be trusted.
		File.saveContent(source, "other contents
");
		var second = cache.file(source);
		expect(second == Sha256.make(File.getBytes(source)).toHex() && second != first,
			"a same-size rewrite within the timestamp resolution must not return the stale digest");
		expect(cache.hashes == 2, "a racily clean entry is hashed again");
		// A clock far enough ahead makes the file old relative to the hash, so the entry is trusted from then on.
		now += 60.0;
		var third = cache.file(source);
		expect(third == second && cache.hashes == 3, "the lookup after the margin hashes once more and settles");
		expect(cache.file(source) == second && cache.file(source) == second && cache.hashes == 3,
			"a settled entry is served without reading the file");
		File.saveContent(source, "a longer replacement
");
		expect(cache.file(source) == Sha256.make(File.getBytes(source)).toHex()
			&& cache.hashes == 4, "a changed size invalidates a settled entry");
		// One cache per execution keeps its old behaviour: it trusts the signature without a margin.
		var local = new ContentDigestCache(false, new DigestStore(Path.join([root, "local-digests"])));
		local.file(source);
		local.file(source);
		expect(local.hashes == 1, "a per-execution cache serves a freshly written file from memory");
		FileTree.remove(root);
	}

	static function testDigestStore():Void {
		var root = temporaryDirectory("digest-store"),
			source = Path.join([root, "input.txt"]),
			unused = Path.join([root, "unused.txt"]),
			other = Path.join([root, "other.txt"]),
			storePath = Path.join([root, "store", "content-digests"]);
		File.saveContent(source, "first contents\n");
		File.saveContent(unused, "unused\n");
		File.saveContent(other, "other\n");
		// Just written: a hash now is within the margin of the file's times, so the store keeps nothing.
		var racy = new ContentDigestCache(false, new DigestStore(storePath));
		racy.file(source);
		racy.save();
		expect(!FileSystem.exists(storePath), "a digest of a file changed within the margin is not stored");
		// A clock far enough ahead makes the files old relative to the hash, as files last changed long ago are.
		var first = new ContentDigestCache(false, new DigestStore(storePath)), now = Sys.time() + 60.0;
		first.clock = () -> now;
		var digest = first.file(source);
		first.file(unused);
		first.save();
		var second = new ContentDigestCache(false, new DigestStore(storePath));
		expect(second.file(source) == digest && second.hashes == 0,
			"another process reads a settled digest from the store without reading the file");
		File.saveContent(source, "a longer replacement\n");
		var third = new ContentDigestCache(false, new DigestStore(storePath));
		expect(third.file(source) == Sha256.make(File.getBytes(source)).toHex() && third.hashes == 1,
			"a changed file is hashed again, not served from the store");
		// A year on, a process that hashes another file drops the entry it neither used nor made.
		var later = now + 365 * 24 * 3600.0,
			aged = new DigestStore(storePath),
			agedCache = new ContentDigestCache(false, aged);
		aged.clock = () -> later;
		agedCache.clock = () -> later;
		agedCache.file(other);
		agedCache.save();
		var after = new ContentDigestCache(false, new DigestStore(storePath));
		after.file(other);
		expect(after.hashes == 0, "a save keeps the digests it made");
		after.file(unused);
		expect(after.hashes == 1, "a save drops the entries that are old and unused");
		File.saveContent(storePath, "not a digest store\n");
		var corrupt = new ContentDigestCache(false, new DigestStore(storePath));
		expect(corrupt.file(source) == Sha256.make(File.getBytes(source)).toHex() && corrupt.hashes == 1,
			"an unreadable store is an empty one");
		FileTree.remove(root);
	}

	static function testSharedDigestsAcrossExecutions():Void {
		var root = temporaryDirectory("shared-digests"),
			buildRoot = Path.join([root, "build"]),
			source = Path.join([root, "input.txt"]),
			output = Path.join([root, "output.txt"]);
		File.saveContent(source, "version one
");
		var environment = new BuildEnvironment(root, buildRoot),
			runs = 0,
			action = new ExecutionAction(new ActionId("shared-digests"), [], [source], [output], "write output",
				Compiler("compiler", [], root, new Map(), () -> {
					runs++;
					File.saveContent(output, "built
");
					return 0;
				}));
		var session = new BuildSession();
		var executor = () -> new Executor(environment, 1, _ -> {}, session.digests);
		expect(executor().execute(new ExecutionPlan([action])).exitCode == 0 && runs == 1,
			"the first execution runs the action");
		var again = executor().execute(new ExecutionPlan([action]));
		expect(again.actions[0].skipped && runs == 1, "an unchanged input is skipped on a shared cache");
		expect(ActionFingerprint.compute(action, buildRoot, environment.target.toString(), [],
			session.digests) == ActionFingerprint.compute(action, buildRoot, environment.target.toString(), []),
			"a shared cache yields the fingerprint a fresh one does");
		File.saveContent(source, "version two
");
		var edited = executor().execute(new ExecutionPlan([action]));
		expect(edited.exitCode == 0 && !edited.actions[0].skipped && runs == 2,
			"an edited input reruns the action through a shared cache");
		File.saveContent(source, "version 333
");
		File.saveContent(source, "version 444
");
		expect(!executor().execute(new ExecutionPlan([action])).actions[0].skipped && runs == 3,
			"a same-size edit right after a build still reruns the action");
		FileTree.remove(root);
	}

	static function testWorkerVersionMemo():Void {
		var session = new BuildSession(), computed = 0, compute = () -> "version-" + (++computed);
		expect(session.workerVersion("identity-a", compute) == "version-1"
			&& session.workerVersion("identity-a", compute) == "version-1"
			&& computed == 1,
			"a worker version is computed once per identity");
		expect(session.workerVersion("identity-b", compute) == "version-2"
			&& session.workerVersionsComputed == 2, "a different identity gets its own version");
		var root = temporaryDirectory("worker-memo"),
			source = Path.join([root, "compiler"]),
			home = Path.join([root, "home"]);
		FileSystem.createDirectory(Path.join([home, "stdlib"]));
		File.saveContent(Path.join([home, build.HaxeonSdk.MANIFEST]), '[roots]\nstdlib = "stdlib"\n');
		FileSystem.createDirectory(source);
		File.saveContent(Path.join([source, "A.hx"]), "class A {}
");
		var one = CompilerClient.workerVersion("haxe", source, home, root, null, session),
			baseline = session.workerVersionsComputed;
		File.saveContent(Path.join([source, "A.hx"]), "class A { var x:Int; }
");
		expect(CompilerClient.workerVersion("haxe", source, home, root, null, session) == one
			&& session.workerVersionsComputed == baseline,
			"a watch session keeps the worker it chose after the compiler sources change");
		expect(CompilerClient.workerVersion("haxe", source, home, root, null) != one,
			"without a session the version follows the sources");
		expect(CompilerClient.workerVersion("haxe", source, home, root, "4242", session) != one,
			"a profile port selects a different worker");
		FileTree.remove(root);
	}

	/** The watch snapshot stats each Haxe file under the source roots and the manifest, and nothing else. */
	@:access(tools.WatchRun)
	static function testWatchSnapshot():Void {
		var root = temporaryDirectory("watch-snapshot");
		writePackage(root, '{"version":1,"package":{"name":"watched"},"entry":"Main","sourceRoots":["src"]}',
			[
				"src/Main.hx",
				"src/deep/er/B.hx",
				"src/notes.txt",
				"src/folder.hx/C.hx"
			]);
		ensureDirectory(Path.join([root, "src", "empty"]));
		var project = ProjectDiscovery.discover(Path.join([root, "haxeon.json"])),
			files = WatchRun.snapshot(project),
			names = [
				for (path in files.keys())
					path.split("\\").join("/").substr(root.split("\\").join("/").length + 1)
			];
		names.sort(Reflect.compare);
		expect(names.join(",") == "haxeon.json,src/Main.hx,src/deep/er/B.hx,src/folder.hx/C.hx",
			"the snapshot holds the manifest and the Haxe files, not directories or other files: " + names.join(","));
		for (path => stamp in files) {
			var stat = FileSystem.stat(path);
			expect(stamp == '${stat.mtime.getTime()}:${stat.size}',
				"a snapshot entry is the file's modification time and size");
		}
		File.saveContent(Path.join([root, "src", "Main.hx"]), "class Main { static function main() {} }
");
		expect(!WatchRun.same(files, WatchRun.snapshot(project)), "an edit changes the snapshot");
		FileTree.remove(root);
	}

	#if (target.threaded && !eval)
	/**
	 * A save that lands while a build runs is built next, after a failed build and after a successful one. Three quick saves
	 * once left the app on the first: its build failed and the watch loop took the snapshot after it as built.
	 */
	static function testWatchBuildsSavesMadeDuringABuild():Void {
		var root = temporaryDirectory("watch-during-build");
		writePackage(root, '{"version":1,"package":{"name":"watched"},"entry":"Main","sourceRoots":["src"]}',
			["src/Main.hx"]);
		var project = ProjectDiscovery.discover(Path.join([root, "haxeon.json"])),
			source = Path.join([
				root,
				"src",
				"Main.hx"
			]);
		var saves = 1;
		function save():Void File.saveContent(source,
			"class Main { static function main() {} }" + StringTools.lpad("", " ", saves++) + "\n");
		Thread.create(function() {
			Sys.sleep(1.0);
			save();
		});
		var builds:Array<String> = [];
		var program = Sys.programPath();
		// The app sleeps long enough for every build; each successful build relaunches it.
		var status = WatchRun.run(project, Sys.executablePath(), program, ["--watch-test-app", "6"], null, "Main", null,
			function(_) {
				builds.push(File.getContent(source));
				switch builds.length {
					case 1:
						// Saved during the first build, which fails.
						save();
						return null;
					case 2:
						// Saved during the second build, which succeeds.
						save();
						return project;
					default:
						return null;
				}
			}, compiler.tools.Verbosity.Minimal);
		expect(status == 0, "the watched app exits normally");
		expect(builds.length == 3, 'every save made during a build is built: ${builds.length} builds for 3 saves');
		expect(builds[2] == File.getContent(source), "the last build saw the last save");
		var kinds:Array<String> = [];
		for (line in File.getContent(WatchEvents.pathFor(program)).split("\n"))
			if (line.length > 0)
				kinds.push(haxe.Json.parse(line).kind);
		expect(kinds.join(",")
			== "rebuild-started,build-failed,rebuild-started,build-ok,reload,rebuild-started,build-failed",
			"the events file records each rebuild and its result: " + kinds.join(","));
		expect(Sys.getEnv(WatchEvents.ENVIRONMENT) == WatchEvents.pathFor(program),
			"the watched app learns the events file from its environment");
		FileSystem.deleteFile(WatchEvents.pathFor(program));
		FileTree.remove(root);
	}
	#end

	/** Build output reaches the events file line by line, however a child process splits it, as one JSON object per line. */
	static function testWatchEventsFile():Void {
		var lines:Array<String> = [];
		OutputCapture.begin(line -> lines.push(line));
		OutputCapture.record("src/A.hx:4:2: E1005: Missing return\r\nsecond ");
		OutputCapture.record("half\n");
		build.BuildOutput.line("compiler: 12 ms");
		OutputCapture.record("unterminated");
		OutputCapture.end();
		OutputCapture.record("not captured\n");
		expect(lines.join("|") == "src/A.hx:4:2: E1005: Missing return|second half|compiler: 12 ms|unterminated",
			"each printed line is delivered once, whole: " + lines.join("|"));
		var root = temporaryDirectory("watch-events"), path = WatchEvents.pathFor(Path.join([root, "live.hl"]));
		File.saveContent(path, "stale\n");
		WatchEvents.reset(path);
		WatchEvents.emit(path, "rebuild-started", 1, null, null, ["src/A.hx"]);
		WatchEvents.emit(path, "output-line", 1, null, "src/A.hx:4:2: E1005: \"quoted\"");
		WatchEvents.emit(path, "patch-rejected", null, 3, null, null, null, "refused");
		WatchEvents.emit(null, "ignored");
		var events:Array<Dynamic> =
			[for (line in File.getContent(path).split("\n")) if (line.length > 0) haxe.Json.parse(line)];
		expect(events.length == 3, "a new watch starts the file empty, one line per event: " + events.length);
		expect(events[0].kind == "rebuild-started" && events[0].build == 1 && events[0].changedFiles[0] == "src/A.hx"
			&& events[0].time > 0,
			"an event carries its kind, time and fields");
		expect(events[1].line == "src/A.hx:4:2: E1005: \"quoted\"", "an output line survives JSON quoting");
		expect(events[2].revision == 3 && events[2].message == "refused" && events[2].build == null,
			"fields that do not apply are null");
		// A rebuild's output lines are queued and appended in batches; all of them are in the file, in order, before the
		// event written after the batch is closed.
		WatchEvents.reset(path);
		var batch = new WatchEventLines(path, 2);
		OutputCapture.begin(batch.add);
		for (index in 0...500)
			OutputCapture.record('line $index\n');
		var waited = 0.0;
		while (File.getContent(path).split("\n").length - 1 < 500 && waited < 10.0) {
			Sys.sleep(0.05);
			waited += 0.05;
		}
		expect(File.getContent(path).split("\n").length - 1 == 500,
			"queued lines reach the file while the build still runs");
		OutputCapture.record("last\n");
		OutputCapture.end();
		batch.close();
		WatchEvents.emit(path, "build-failed", 2);
		var batched:Array<Dynamic> =
			[for (line in File.getContent(path).split("\n")) if (line.length > 0) haxe.Json.parse(line)];
		expect(batched.length == 502, "every output line is written once, then the result: " + batched.length);
		var ordered = batched.length == 502 && batched[500].line == "last" && batched[501].kind == "build-failed";
		if (ordered)
			for (index in 0...500)
				if (batched[index].kind != "output-line" || batched[index].build != 2
					|| batched[index].line != 'line $index')
					ordered = false;
		expect(ordered, "batched output lines keep their order and come before the build's result");
		// A file that cannot be written (its path is a directory) is not the build's problem.
		var blocked = new WatchEventLines(root, 3);
		blocked.add("dropped");
		blocked.close();
		FileTree.remove(root);
	}

	static function testWatchChangeClassification():Void {
		var before = ["src/A.hx" => "1:10", "src/B.hx" => "1:20", "haxeon.json" => "1:30"];
		var edited = ["src/A.hx" => "2:11", "src/B.hx" => "1:20", "haxeon.json" => "1:30"];
		var change = WatchRun.classify(before, edited);
		expect(change.compilerOnly && !change.structural, "editing a Haxe file's contents keeps the resolved project");
		var added = [
			"src/A.hx" => "1:10",
			"src/B.hx" => "1:20",
			"src/C.hx" => "2:5",
			"haxeon.json" => "1:30"
		];
		change = WatchRun.classify(before, added);
		expect(change.compilerOnly && change.structural, "a new Haxe file changes the project's sources");
		var removed = ["src/A.hx" => "1:10", "haxeon.json" => "1:30"];
		change = WatchRun.classify(before, removed);
		expect(change.compilerOnly && change.structural, "a deleted Haxe file changes the project's sources");
		var manifest = ["src/A.hx" => "1:10", "src/B.hx" => "1:20", "haxeon.json" => "2:31"];
		change = WatchRun.classify(before, manifest);
		expect(!change.compilerOnly && change.structural, "a manifest edit forces a new resolution");
		var native = [
			"src/A.hx" => "1:10",
			"src/B.hx" => "1:20",
			"haxeon.json" => "1:30",
			"native/x.c" => "1:1"
		];
		change = WatchRun.classify(before, native);
		expect(!change.compilerOnly && change.structural, "a new native file forces a new resolution");
	}

	/** A save wakes the watch loop within tens of milliseconds, including editors that save by rename or replace. */
	static function testDirectoryWatcher():Void {
		var root = temporaryDirectory("directory-watcher");
		FileSystem.createDirectory(Path.join([root, "src"]));
		var target = Path.join([root, "src", "A.hx"]);
		File.saveContent(target, "one");
		FileSystem.createDirectory(Path.join([root, "build"]));
		var watcher = DirectoryWatcher.create([{path: root, recursive: true}], [Path.join([root, "build"])]);
		if (watcher == null) {
			FileTree.remove(root);
			return;
		}
		expect(!watcher.wait(0.05), "an idle tree reports no change");
		var start = Sys.time();
		File.saveContent(target, "two");
		expect(watcher.wait(2.0), "a save is reported");
		expect(Sys.time() - start < 0.25, "a save is reported within tens of milliseconds, not a polling interval");
		while (watcher.wait(0.05)) {}
		File.saveContent(target + ".tmp", "three");
		FileSystem.deleteFile(target);
		FileSystem.rename(target + ".tmp", target);
		expect(watcher.wait(2.0), "a save by rename is reported");
		while (watcher.wait(0.05)) {}
		File.saveContent(Path.join([root, "src", "B.hx"]), "new");
		expect(watcher.wait(2.0), "a new file is reported");
		while (watcher.wait(0.05)) {}
		FileSystem.createDirectory(Path.join([root, "src", "late", "deeper"]));
		expect(watcher.wait(2.0), "a new directory is reported");
		while (watcher.wait(0.05)) {}
		File.saveContent(Path.join([root, "src", "late", "deeper", "C.hx"]), "nested");
		expect(watcher.wait(2.0), "a file in a directory created after the watch started is reported");
		while (watcher.wait(0.05)) {}
		File.saveContent(Path.join([root, "build", "out.hl"]), "output");
		expect(!watcher.wait(0.2), "a change in an excluded directory is not reported");
		watcher.close();
		FileTree.remove(root);
	}

	static function testDelegatedNativeInvalidation():Void {
		var root = temporaryDirectory("delegated-native"),
			buildRoot = Path.join([root, "build"]),
			nativeSource = Path.join([root, "native.c"]),
			binding = Path.join([root, "api.hxi"]),
			stamp = Path.join([root, "native.stamp"]),
			output = Path.join([root, "app.hl"]),
			nativeRuns = 0,
			compilerRuns = 0,
			failNative = false;
		File.saveContent(nativeSource, "first native implementation");
		File.saveContent(binding, "first binding");
		var nativeAction = new ExecutionAction(new ActionId("native-cmake-build:fixture"), [], [nativeSource], [stamp],
			"native",
			Compiler("fixture-native", [], root, new Map(),
			() -> {
				nativeRuns++;
				File.saveContent(stamp, Std.string(nativeRuns));
				return failNative ? 1 : 0;
			}),
				true, true),
				compileAction = new ExecutionAction(new ActionId("fixture-compile"), [nativeAction.id], [binding],
				[output], "compile",
				Compiler("fixture-compiler", [], root, new Map(), () -> {
			compilerRuns++;
			File.saveContent(output, "bytecode");
			return 0;
		}), false),
			plan = new ExecutionPlan([nativeAction, compileAction]),
			environment = new BuildEnvironment(root, buildRoot);
		expect(new Executor(environment, 1, _ -> {}).execute(plan).exitCode == 0, "initial delegated build succeeds");
		File.saveContent(nativeSource, "changed native implementation");
		expect(new Executor(environment, 1, _ -> {}).execute(plan).exitCode == 0 && nativeRuns == 2
			&& compilerRuns == 1,
			"native changes run the delegate without recompiling independent bytecode");
		File.saveContent(binding, "changed FFI binding");
		expect(new Executor(environment, 1, _ -> {}).execute(plan).exitCode == 0 && compilerRuns == 2,
			"binding changes still recompile bytecode");
		failNative = true;
		var failed = new Executor(environment, 1, _ -> {}).execute(plan);
		expect(failed.exitCode != 0 && failed.actions[1].blocked && compilerRuns == 2,
			"a failed ordering dependency blocks even cached bytecode");
		var stampAction = new ExecutionAction(new ActionId("native-cmake-build:stamp"), [], [], [stamp], "stamp",
			Process("cmake", [], root, new Map()));
		expect(!build.execution.ArtifactCache.isShareable(stampAction),
			"CMake package stamps cannot restore missing runtime libraries");
		FileTree.remove(root);
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
		var firstAction = new ExecutionAction(new ActionId("portable-copy"), [], [firstSource], [firstOutput],
			"portable copy",
			Process("sh", [
				"-c",
				'cp "$firstSource" "$firstOutput"'
			], firstRoot, new Map())),
			secondAction = new ExecutionAction(new ActionId("portable-copy"), [], [secondSource], [secondOutput],
				"portable copy",
				Process("sh", [
					"-c",
					'cp "$secondSource" "$secondOutput"'
				], secondRoot, new Map())),
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
		FileTree.remove(cache);
		FileTree.remove(firstRoot);
		FileTree.remove(secondRoot);
	}

	static function testProjectDiscovery():Void {
		var root = temporaryDirectory("discovery"),
			app = Path.join([root, "app"]),
			foo = Path.join([root, "foo"]),
			bar = Path.join([root, "bar"]);
		writePackage(app,
			'{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"dependencies":{"foo":{"path":"../foo"}}}',
			["src/Main.hx"]);
		writePackage(foo,
			'{"version":1,"package":{"name":"foo"},"sourceRoots":["src"],"dependencies":{"bar":{"path":"../bar"}},"native":{"sources":["native/foo.c"],"includeDirs":["native"],"std":"c++20"}}',
			[
				"src/Foo.hx",
				"native/foo.c",
				"native/foo.h"
			]);
		writePackage(bar, '{"version":1,"package":{"name":"bar"},"sourceRoots":["src"]}', ["src/Bar.hx"]);
		var project = ProjectDiscovery.discover(Path.join([app, "haxeon.json"]));
		expect(project.rootPackage.name == "app", "root package should be identified");
		expect(project.packages.names().join(",") == "bar,foo,app",
			"nested packages should be ordered dependency-first");
		expect(project.packages.get("foo").nativeSources.length == 1
			&& project.packages.get("foo").includeDirs.length == 1,
			"native package metadata should be resolved");
		expect(project.packages.get("foo").manifest.native.standard == "c++20",
			"native language standards should be resolved from package metadata");
		expect(project.rootPackage.sources.length == 1 && project.rootPackage.sources[0].indexOf("Main.hx") >= 0,
			"source roots should expand into a deterministic Haxe source manifest");
		var environment = new BuildEnvironment(project.root, Path.join([project.root, "build"])),
			plan = BuildPlanner.project(project, BuildIntent.Build, environment.target, NativeArtifactDemand.Shared),
			execution = PlanLowerer.lower(plan,
				new LoweringContext(environment, null, project,
				new TargetLayout(environment).hashLinkModulePath("main"), sdk())),
			executionText = execution.toDebugString();
		expect(plan.toExplainString().indexOf("reason: requested output") >= 0
			&& plan.toExplainString().indexOf("detail library: foo") >= 0,
			"plan explanations should identify requested outputs and provider details");
		expect(executionText.indexOf("kind: process") >= 0
			&& executionText.indexOf("kind: compiler") >= 0
			&& executionText.indexOf("outputs:") >= 0,
			"execution plans should expose action kinds and outputs");
		expect(plan.toDebugString().indexOf("foo:NativeSharedLibrary") >= 0,
			"the package build plan should require its shared native library");
		expect(plan.toDebugString().indexOf("foo:NativeStaticLibrary") < 0,
			"the package build plan should not create an unrequested native archive");
		expect(executionText.indexOf("Compile C") >= 0
			&& executionText.indexOf("Archive foo") < 0
			&& executionText.indexOf("Link shared library foo") >= 0
			&& executionText.indexOf("Compile Haxe package") >= 0,
			"native sources, the requested shared library, and Haxe compilation should lower to concrete actions");
		// The compiler reads only FFI interfaces, so it does not wait for native package actions and the two build side by side.
		var compileAction = compilerAction(execution);
		expect(compileAction != null && compileAction.dependencies.length == 0,
			"the Haxe compiler request must not wait for native package actions");
		var hasDescriptorBinary = false, hasDescriptorJson = false;
		for (output in compileAction.outputs) {
			hasDescriptorBinary = hasDescriptorBinary || StringTools.endsWith(output, ".descriptors");
			hasDescriptorJson = hasDescriptorJson || StringTools.endsWith(output, ".descriptors.json");
		}
		expect(hasDescriptorBinary && hasDescriptorJson,
			"project module builds must track both descriptor sidecar outputs");
		expect(execution.actions.length > 1, "the native package actions are still part of the plan");
		// ... but whatever runs the module waits for everything built for it, the native libraries it loads included.
		if (Sys.systemName() != "Windows") {
			var member = new LoweredWorkspaceProject("app", project,
				new TargetLayout(environment).hashLinkModulePath("main"),
				[for (action in execution.actions) action.id]),
				tests = WorkspaceBuild.withTests(new LoweredWorkspace(environment, execution, [member],
					execution.actions.length, new Map()), sdk()),
				testAction = [
					for (action in tests.actions)
						if (StringTools.startsWith(action.id.key(), "test:")) action
				][0];
			expect(testAction != null && [
				for (action in execution.actions)
					if (testAction.dependencies.indexOf(action.id) < 0) action
			].length == 0,
				"a workspace test must wait for the compile and the native actions of its project");
		}
		// Only live sessions ask the compiler to keep the history patches address a running module by.
		var compilerArguments = function(plan:ExecutionPlan):Array<String> {
			var compile = compilerAction(plan);
			return switch compile.action {
				case Compiler(_, arguments, _, _, _): arguments;
				default: [];
			};
		}, liveExecution = PlanLowerer.lower(plan,
			new LoweringContext(environment, null, project, new TargetLayout(environment).hashLinkModulePath("main"),
			sdk(), null, false, false, true));
		expect(compilerArguments(execution).indexOf("--live") < 0,
			"an ordinary build must not request live compiler history");
		expect(compilerArguments(liveExecution).indexOf("--live") >= 0,
			"a live build must request live compiler history");
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

		var staticPlan = BuildPlanner.project(project, BuildIntent.Build, environment.target,
			NativeArtifactDemand.Static),
			staticPlanText = staticPlan.toDebugString();
		expect(staticPlanText.indexOf("foo:NativeStaticLibrary") >= 0
			&& staticPlanText.indexOf("foo:NativeSharedLibrary") < 0,
			"an explicit static native demand should create only the archive");

		var missing = Path.join([root, "missing-app"]);
		writePackage(missing,
			'{"version":1,"package":{"name":"missing-app"},"entry":"Main","dependencies":{"foo":{"path":"../absent"}}}',
			["src/Main.hx"]);
		expectThrows(() -> ProjectDiscovery.discover(Path.join([missing, "haxeon.json"])),
			"missing dependency paths should be reported");

		var duplicate = Path.join([root, "duplicate"]),
			first = Path.join([root, "first-shared"]),
			second = Path.join([root, "second-shared"]),
			nested = Path.join([duplicate, "foo"]);
		writePackage(duplicate,
			'{"version":1,"package":{"name":"duplicate"},"dependencies":{"foo":{"path":"foo"},"shared":{"path":"../first-shared"}}}',
			[]);
		writePackage(nested,
			'{"version":1,"package":{"name":"foo"},"dependencies":{"shared":{"path":"../../second-shared"}}}', []);
		writePackage(first, '{"version":1,"package":{"name":"shared"}}', []);
		writePackage(second, '{"version":1,"package":{"name":"shared"}}', []);
		expectThrows(() -> ProjectDiscovery.discover(Path.join([duplicate, "haxeon.json"])),
			"duplicate package names should be reported");

		var cycle = Path.join([root, "cycle"]),
			child = Path.join([cycle, "child"]);
		writePackage(cycle, '{"version":1,"package":{"name":"cycle"},"dependencies":{"child":{"path":"child"}}}', []);
		writePackage(child, '{"version":1,"package":{"name":"child"},"dependencies":{"cycle":{"path":".."}}}', []);
		expectThrows(() -> ProjectDiscovery.discover(Path.join([cycle, "haxeon.json"])),
			"path dependency cycles should be reported");
		FileTree.remove(root);
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
		expect(dependencies.length == 2 && dependencies[0].indexOf("first.h") >= 0
			&& dependencies[1].indexOf("second.h") >= 0,
			"native dependency scanning should follow recursive local includes");
		FileTree.remove(root);
	}

	static function testFfiProjectIntegration():Void {
		var root = temporaryDirectory("ffi-project"),
			app = Path.join([root, "app"]),
			manifestPath = Path.join([app, "ffi", "fixture.ffi.json"]),
			headerPath = Path.join([app, "headers", "fixture.hpp"]);
		writePackage(app,
			'{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"ffi":{"imports":["ffi/fixture.ffi.json"]}}',
			["src/Main.hx"]);
		ensureDirectory(Path.directory(manifestPath));
		ensureDirectory(Path.directory(headerPath));
		File.saveContent(headerPath, "namespace fixture { class Widget { public: void reset() noexcept; }; }\n");
		File.saveContent(manifestPath,
			'{"version":1,"name":"fixture","language":"c++","profile":"direct","header":"../headers/fixture.hpp","std":"c++20","library":"fixture","interface":"Fixture","select":["fixture::Widget::reset"],"projection":true}\n');
		var project = ProjectDiscovery.discover(Path.join([app, "haxeon.json"]));
		expect(project.rootPackage.ffiImports.length == 1
			&& project.rootPackage.ffiImports[0].config.name == "fixture"
			&& project.rootPackage.ffiImports[0].config.profile == "direct"
			&& project.rootPackage.ffiImports[0].header == FileSystem.fullPath(headerPath),
			"project resolution should load FFI recipes relative to the package");
		expectThrows(() -> FfiImportManifest.parse("/tmp/direct.ffi.json",
			'{"version":1,"name":"direct","language":"c++","profile":"direct","header":"fixture.hpp","library":"fixture","cxxThunks":true}'),
			"direct C++ FFI profiles should reject generated thunks");
		// The compiler home is the checkout's SDK: the FFI import runs its own `haxeon`, in the SDK's bin.
		var environment = new BuildEnvironment(project.root, Path.join([project.root, "build"])),
			plan = BuildPlanner.project(project, BuildIntent.Build, environment.target, NativeArtifactDemand.Shared),
			execution = PlanLowerer.lower(plan,
				new LoweringContext(environment, null, project,
				new TargetLayout(environment).hashLinkModulePath("main"), sdk())),
			planText = plan.toDebugString(),
			executionText = execution.toDebugString();
		expect(planText.indexOf("app:FfiInterface") >= 0
			&& executionText.indexOf("Import c++ FFI fixture") >= 0
			&& executionText.indexOf("projection.sources") >= 0
			&& executionText.indexOf("Compile Haxe package") >= 0,
			"project FFI recipes should become build artifacts before Haxe compilation");
		FileTree.remove(root);
	}

	/** The one translation of a project into compiler inputs, which the build renders and the language server reads. */
	static function testCompilerInputs():Void {
		var root = temporaryDirectory("compiler-inputs"),
			app = Path.join([root, "app"]),
			lib = Path.join([root, "lib"]);
		writePackage(app,
			'{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"defines":["app-flag"],"inline":false,"dependencies":{"lib":{"path":"../lib"}},"ffi":{"imports":["ffi/fixture.ffi.json"]}}',
			["src/Main.hx", "src/Zed.hx", "headers/fixture.hpp"]);
		ensureDirectory(Path.join([app, "ffi"]));
		File.saveContent(Path.join([app, "ffi", "fixture.ffi.json"]),
			'{"version":1,"name":"fixture","language":"c++","profile":"direct","header":"../headers/fixture.hpp","std":"c++20","library":"fixture","interface":"Fixture","select":["fixture::Widget::reset"],"projection":true}\n');
		writePackage(lib,
			'{"version":1,"package":{"name":"lib"},"sourceRoots":["src","examples"],"unscopedSourceRoots":["examples"]}',
			["src/Value.hx", "examples/Example.hx"]);
		var project = ProjectDiscovery.discover(Path.join([app, "haxeon.json"])),
			hostLayout = new TargetLayout(new BuildEnvironment(project.root, Path.join([project.root, "build"]))),
			host = CompilerInputs.of(project, hostLayout),
			appRoot = project.packages.get("app").sourceRoots[0],
			libRoot = project.packages.get("lib").sourceRoots[0];
		expect(host.target == "hl" && host.entry == "Main",
			"a host build compiles HashLink code from the manifest's entry");
		expect(host.roots.join(",") == project.packages.get("lib").sourceRoots.concat([appRoot]).join(","),
			"every package's source roots are compiler roots, dependencies first");
		expect(host.packageRoots.length == 1 && host.packageRoots[0].packageName == "lib"
			&& host.packageRoots[0].path == libRoot,
			"a dependency's scoped roots belong to its package; its unscoped roots and the root package's do not");
		var sorted = host.sources.copy();
		sorted.sort(Reflect.compare);
		expect(host.sources.length == 4 && host.sources.join(",") == sorted.join(","),
			"the sources are every package's, sorted");
		expect(host.generatedFfi.length == 1
			&& host.generatedFfi[0].interfacePath == hostLayout.ffiInterfacePath("app", "fixture")
			&& host.generatedFfi[0].projectionRoot == hostLayout.ffiProjectionPath("app", "fixture"),
			"an FFI import is read from where the layout generates it");
		expect(host.defines.join(",") == "app-flag" && !host.inlineEnabled,
			"the manifest's defines and inlining carry over");
		var wasm = CompilerInputs.of(project,
			new TargetLayout(new BuildEnvironment(project.root, Path.join([project.root, "build"]), BuildProfile.Debug,
			Target.parse("wasm32")))),
			android = CompilerInputs.of(project,
				new TargetLayout(new BuildEnvironment(project.root, Path.join([project.root, "build"]),
				BuildProfile.Debug,
				Target.parse("android-arm64"))));
		expect(wasm.target == "wasm32" && wasm.generatedFfi[0].interfacePath.indexOf("wasm32") >= 0,
			"a Wasm layout compiles Wasm and reads FFI imports from its own directory");
		expect(android.target == "hl" && android.defines.join(",") == "android,app-flag",
			"an Android build compiles HashLink code with the android define");
		// The CLI builds wasm32 through the structured build, whatever target the manifest names.
		expect(BuildPlanner.project(ProjectDiscovery.discover(Path.join([lib, "haxeon.json"])), BuildIntent.Build,
			Target.parse("wasm32"), NativeArtifactDemand.Shared)
			.toDebugString()
			.indexOf("lib:WasmModule") >= 0, "a wasm32 build plans a Wasm module");
		// The build passes exactly these to the compiler.
		var environment = new BuildEnvironment(project.root, Path.join([project.root, "build"])),
			execution = PlanLowerer.lower(BuildPlanner.project(project, BuildIntent.Build, environment.target,
				NativeArtifactDemand.Shared),
				new LoweringContext(environment, null, project, hostLayout.hashLinkModulePath("main"), sdk())),
			arguments = switch compilerAction(execution).action {
				case Compiler(_, arguments, _, _, _): arguments;
				case _: [];
			};
		for (expected in [
			"--target=hl",
			'--package-root=lib=$libRoot',
			"--root=" + appRoot,
			"--ffi-interface=" + host.generatedFfi[0].interfacePath,
			"--define=app-flag",
			"--no-inline"
		])
			expect(arguments.indexOf(expected) >= 0, 'the compile request should pass $expected');
		expect(arguments.indexOf('--package-root=app=$appRoot') < 0,
			"the root package is not scoped when its entry is outside it");
		expect(arguments.indexOf("--live") < 0, "a host build is not live unless asked");
		// An Android module is built live for the debug host, with the baseline its edits compile against and main's stable ID.
		var androidTarget = Target.parse("android"),
			androidEnvironment = new BuildEnvironment(project.root, Path.join([project.root, "build"]),
				BuildProfile.Release,
				androidTarget),
			module = new TargetLayout(androidEnvironment).hashLinkModulePath("app");
		function androidCompile(?baseline:String):ExecutionAction
			return compilerAction(PlanLowerer.lower(BuildPlanner.project(project, BuildIntent.Build, androidTarget,
				NativeArtifactDemand.Shared),
				new LoweringContext(androidEnvironment, null, project, module, sdk(), null, null, null, null,
				null, null,
				false, baseline)));
		function compilerArguments(action:ExecutionAction):Array<String>
			return switch action.action {
				case Compiler(_, arguments, _, _, _): arguments;
				case _: [];
			};
		var androidBuild = androidCompile(), androidArguments = compilerArguments(androidBuild);
		for (expected in [
			"--live",
			"--build-mode=development",
			"--define=android",
			"--baseline-output=" + module + ".hcs",
			"--entry-id-output=" + module + ".entry"
		])
			expect(androidArguments.indexOf(expected) >= 0, 'an Android compile request should pass $expected');
		expect(androidBuild.outputs.indexOf(module + ".hcs") >= 0
			&& androidBuild.outputs.indexOf(module + ".entry") >= 0
			&& androidBuild.outputs.indexOf(module + ".hli") >= 0,
			"an Android build declares its baseline, entry ID and runtime identity");
		expect(!Lambda.exists(androidArguments, argument -> StringTools.startsWith(argument, "--baseline=")),
			"a build compiles against no baseline");
		var baseline = module + ".hcs", edit = androidCompile(baseline);
		expect(compilerArguments(edit).indexOf("--baseline=" + baseline) >= 0 && edit.inputs.indexOf(baseline) >= 0,
			"an edit compiles against the baseline, which is one of its inputs");
		expect(module == HaxeonProjectBuild.androidModulePath(project, androidTarget),
			"the CLI and Gradle find the module where the build writes it");
		FileTree.remove(root);
	}

	/**
	 * Offline resolution (the editor's) takes a Git dependency only from the source cache, at the commit the lockfile names: it
	 * neither resolves a ref nor clones.
	 */
	static function testOfflineGitResolution():Void {
		var root = temporaryDirectory("offline-git"),
			repository = Path.join([root, "repository"]),
			app = Path.join([root, "app"]),
			previousCache = Sys.getEnv("HAXEON_SOURCE_CACHE");
		writePackage(repository, '{"version":1,"package":{"name":"dep"},"sourceRoots":["src"]}', ["src/Dep.hx"]);
		var git = (arguments:Array<String>) -> ProcessRunner.capture("git", ["-C", repository].concat(arguments));
		for (command in [
			["init", "-q"],
			["add", "-A"],
			["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "dep"]
		])
			expect(git(command).status == 0, "could not prepare the Git fixture");
		var commit = StringTools.trim(git(["rev-parse", "HEAD"]).output);
		Sys.putEnv("HAXEON_SOURCE_CACHE", Path.join([root, "cache"]));
		try {
			writePackage(app,
				'{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"dependencies":{"dep":{"git":"$repository","rev":"$commit"}}}',
				["src/Main.hx"]);
			var manifest = Path.join([app, "haxeon.json"]);
			expectThrows(() -> ProjectDiscovery.resolve(manifest, null, true),
				"offline resolution must not clone a dependency missing from the source cache");
			expect(ProjectDiscovery.resolve(manifest).packages.get("dep") != null,
				"online resolution clones the dependency");
			expect(ProjectDiscovery.resolve(manifest, null, true).packages.get("dep") != null,
				"offline resolution uses the cached checkout");
			writePackage(app,
				'{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"dependencies":{"dep":{"git":"$repository","rev":"HEAD"}}}',
				["src/Main.hx"]);
			expectThrows(() -> ProjectDiscovery.resolve(manifest, null, true),
				"offline resolution must not ask the remote what a ref names");
			File.saveContent(ProjectDiscovery.lockfilePath(manifest),
				ProjectDiscovery.resolve(manifest).lockfile.toJson());
			expect(ProjectDiscovery.resolve(manifest, null, true).packages.get("dep") != null,
				"offline resolution follows the lockfile's commit for a ref");
		} catch (error:Dynamic) {
			Sys.putEnv("HAXEON_SOURCE_CACHE", previousCache == null ? "" : previousCache);
			FileTree.remove(root);
			throw error;
		}
		Sys.putEnv("HAXEON_SOURCE_CACHE", previousCache == null ? "" : previousCache);
		FileTree.remove(root);
	}

	static function testPackageSourceModel():Void {
		var manifest = PackageManifest.parse("/tmp/example/haxeon.json",
			'{"package":{"name":"app"},"sourceRoots":["src","examples"],"unscopedSourceRoots":["examples"],"dependencies":{"git-dependency":{"git":"https://example.invalid/foo.git","rev":"main"},"path-dependency":{"path":"../path-dependency"}}}');
		expect(manifest.packageId.equals(new project.PackageId("app")),
			"package manifests should expose stable package identity");
		expect(manifest.unscopedSourceRoots.length == 1 && manifest.unscopedSourceRoots[0] == "examples",
			"packages should select source roots that remain outside their namespace");
		var git = manifest.dependencies.get("git-dependency"),
			path = manifest.dependencies.get("path-dependency");
		expect(git != null && path != null
			&& PackageSourceTools.describe(git.source) == "git:https://example.invalid/foo.git@main",
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
		var badVersion = PackageManifest.parse("/tmp/incompatible/haxeon.json",
			'{"package":{"name":"incompatible"},"compatibility":{"haxeon":">=0.4"}}');
		rejected = null;
		try {
			badVersion.compatibility.validate("incompatible", Target.detectHost());
		} catch (error:Dynamic) {
			rejected = Std.string(error);
		}
		expect(rejected != null
			&& rejected.indexOf("requires Haxeon") >= 0,
			"package compatibility should reject incompatible Haxeon versions");
	}

	static function testHaxelibAdapter():Void {
		var root = temporaryDirectory("haxelib"),
			app = Path.join([root, "app"]),
			cache = Path.join([root, "cache"]),
			foo = Path.join([cache, "foo", "1.0.0"]);
		writePackage(app, '{"package":{"name":"app"},"dependencies":{"foo":{"haxelib":"foo","version":"1.0.0"}}}', []);
		ensureDirectory(Path.join([foo, "src"]));
		File.saveContent(Path.join([foo, "haxelib.json"]),
			'{"name":"foo","version":"1.0.0","classPath":"src","dependencies":{}}\n');
		File.saveContent(Path.join([foo, "src", "Foo.hx"]), "class Foo {}\n");
		var project = new PackageResolver(new HaxelibSourceAcquirer(cache)).resolve(Path.join([app, "haxeon.json"]));
		expect(project.packages.get("foo").source != null && FileSystem.exists(Path.join([foo, "haxeon.json"])),
			"Haxelib metadata should be adapted into a cached Haxeon manifest");
		var bad = Path.join([cache, "bad", "1.0.0"]);
		ensureDirectory(bad);
		File.saveContent(Path.join([bad, "haxelib.json"]),
			'{"name":"bad","version":"1.0.0","extraParams":["--macro","bad()"]}\n');
		var badApp = Path.join([root, "bad-app"]);
		writePackage(badApp,
			'{"package":{"name":"bad-app"},"dependencies":{"bad":{"haxelib":"bad","version":"1.0.0"}}}', []);
		expectThrows(() -> new PackageResolver(new HaxelibSourceAcquirer(cache)).resolve(Path.join([
			badApp,
			"haxeon.json"
		])),
			"unsupported Haxelib compiler parameters should be diagnosed");
		FileTree.remove(root);
	}

	static function testRegistryAdapter():Void {
		var root = temporaryDirectory("registry"),
			app = Path.join([root, "app"]),
			cache = Path.join([root, "cache"]),
			registryDirectory = Path.join([cache, Sha256.encode("local")]),
			foo = Path.join([registryDirectory, "foo", "1.1.0"]),
			checksum = "release-checksum";
		writePackage(app, '{"package":{"name":"app"},"dependencies":{"foo":{"registry":"local","version":"^1.0"}}}',
			[]);
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
		expect(locked.packages.get("foo").source != null,
			"locked registry releases should resolve through the same adapter");
		File.saveContent(Path.join([foo, ".haxeon-checksum"]), "tampered\n");
		expectThrows(() -> resolver.resolve(Path.join([app, "haxeon.json"])),
			"registry source checksums should be verified on every use");
		FileTree.remove(root);
	}

	/** A dependency written as a bare version range comes from the registry named `haxeon`, in a JSON and in a TOML manifest. */
	static function testDefaultRegistryShorthand():Void {
		var root = temporaryDirectory("registry-shorthand"),
			cache = Path.join([root, "cache"]),
			registryDirectory = Path.join([cache, Sha256.encode("haxeon")]),
			foo = Path.join([registryDirectory, "foo", "1.1.0"]),
			checksum = "release-checksum";
		ensureDirectory(Path.join([foo, "src"]));
		File.saveContent(Path.join([foo, "haxeon.json"]), '{"package":{"name":"foo"},"sourceRoots":["src"]}\n');
		File.saveContent(Path.join([foo, "src", "Foo.hx"]), "class Foo {}\n");
		File.saveContent(Path.join([foo, ".haxeon-checksum"]), checksum + "\n");
		File.saveContent(Path.join([registryDirectory, "index.json"]),
			'{"version":1,"packages":{"foo":{"versions":[{"version":"1.1.0","checksum":"$checksum"}]}}}\n');
		var json = Path.join([root, "json"]), toml = Path.join([root, "toml"]);
		writePackage(json, '{"package":{"name":"app"},"dependencies":{"foo":"^1.0"}}', []);
		ensureDirectory(Path.join([toml, "src"]));
		File.saveContent(Path.join([toml, "haxeon.toml"]), '[package]\nname = "app"\n\n[dependencies]\nfoo = "^1.0"\n');
		var resolver = new PackageResolver(new RegistrySourceAcquirer(cache));
		for (manifest in [Path.join([json, "haxeon.json"]), Path.join([toml, "haxeon.toml"])]) {
			var entry = resolver.resolve(manifest).lockfile.get("foo");
			expect(entry != null && entry.resolvedRevision == "1.1.0" && entry.checksum == checksum,
				'a bare version range in $manifest should resolve from the haxeon registry');
			expect(entry != null
				&& PackageSourceCodec.equal(entry.source, project.PackageSource.Registry("haxeon", "foo", "^1.0")),
				'a bare version range in $manifest should lock as a haxeon registry source');
		}
		FileTree.remove(root);
	}

	static function testRegistryPublisher():Void {
		var root = temporaryDirectory("registry-publish"),
			packageRoot = Path.join([root, "package"]),
			registryRoot = Path.join([root, "registry"]);
		writePackage(packageRoot,
			'{"package":{"name":"published"},"sourceRoots":["src"],"compatibility":{"targets":["host"]}}',
			["src/Published.hx"]);
		var checksum = RegistryPublisher.publish(Path.join([packageRoot, "haxeon.json"]), registryRoot, "published",
			"1.0.0",
			[]),
			destination = Path.join([registryRoot, "published", "1.0.0"]);
		expect(checksum.length == 64 && FileSystem.exists(Path.join([destination, ".haxeon-checksum"])),
			"registry publication should create a checksum-marked immutable release");
		expectThrows(() -> RegistryPublisher.publish(Path.join([packageRoot, "haxeon.json"]), registryRoot, "published",
			"1.0.0", []),
			"registry publication should reject replacing an existing version");
		FileTree.remove(root);
	}

	/**
	 * A checkout's haxeon registry: live entries resolve from the package's directory under their registry name, with path
	 * dependencies between them as registry dependencies, as publishing writes them; a lockfile entry in range is kept as it is.
	 */
	static function testLiveRegistry():Void {
		var root = temporaryDirectory("live-registry"),
			registry = Path.join([root, "sdk", "registry"]),
			foo = Path.join([root, "packages", "foo"]),
			bar = Path.join([root, "packages", "bar"]),
			app = Path.join([root, "app"]);
		writePackage(foo,
			'{"package":{"name":"repo-foo"},"dependencies":{"repo-bar":{"path":"../bar"}},"publish":{"exclude":["tests"]}}',
			["src/Foo.hx", "tests/FooTest.hx"]);
		writePackage(bar, '{"package":{"name":"repo-bar"}}', ["src/Bar.hx"]);
		writePackage(app, '{"package":{"name":"app"},"dependencies":{"foo":"^0.3"}}', []);
		ensureDirectory(registry);
		File.saveContent(Path.join([registry, "index.json"]),
			'{"version":1,"packages":{"foo":{"versions":[{"version":"0.3.0","path":"../../packages/foo"}]},'
			+ '"bar":{"versions":[{"version":"0.3.0","path":"../../packages/bar"}]}}}\n');
		var resolver = new PackageResolver(new RegistrySourceAcquirer(Path.join([root, "cache"]), registry)),
			manifest = Path.join([app, "haxeon.json"]),
			project = resolver.resolve(manifest),
			entry = project.lockfile.get("foo");
		expect(project.packages.get("foo") != null && project.packages.get("bar") != null
			&& project.packages.get("foo").root == FileSystem.fullPath(foo),
			"a live registry package should resolve from its directory under its registry name, with its path dependency");
		expect(entry != null && entry.resolvedRevision == "0.3.0" && entry.checksum == null
			&& entry.dependencies.length == 1 && entry.dependencies[0].name == "bar",
			"a live registry package should lock its version, no checksum, and its dependencies by registry name");
		var released = new PackageLockfile([
			for (locked in project.lockfile.entries)
				locked.id.name == "foo" ? new PackageLockEntry(locked.id, locked.source, "0.3.7", "released-checksum",
				locked.dependencies) : locked
		]),
			kept = resolver.resolve(manifest, released, true).lockfile.get("foo");
		expect(kept.resolvedRevision == "0.3.7" && kept.checksum == "released-checksum",
			"a live registry package should keep a lockfile's entry in range as it is");
		var published = Json.parse(RegistryPublisher.publishedManifest(Path.join([foo, "haxeon.json"]), "foo", "0.3.0",
			RegistryIndex.load(registry).liveDirectories()));
		expect(Reflect.field(published, "package").name == "foo"
			&& Reflect.field(published, "package").version == "0.3.0"
			&& Reflect.field(published.dependencies, "bar") == "^0.3" && Reflect.field(published, "publish") == null,
			"publishing should rename the package and turn its path dependency into a registry range");
		var release = Path.join([root, "release-registry"]),
			directories = RegistryIndex.load(registry).liveDirectories();
		RegistryPublisher.publish(Path.join([bar, "haxeon.json"]), release, "bar", "0.3.0", directories);
		RegistryPublisher.publish(Path.join([foo, "haxeon.json"]), release, "foo", "0.3.0", directories);
		expect(FileSystem.exists(Path.join([release, "foo", "0.3.0", "src", "Foo.hx"]))
			&& !FileSystem.exists(Path.join([release, "foo", "0.3.0", "tests"])),
			"publishing should copy the package less its publish.exclude");
		var fromRelease = new PackageResolver(new RegistrySourceAcquirer(Path.join([root, "cache"]),
			release)).resolve(manifest);
		expect(fromRelease.lockfile.get("foo").checksum != null
			&& fromRelease.lockfile.get("bar").resolvedRevision == "0.3.0",
			"the published packages should resolve from the release's registry, with checksums");
		FileTree.remove(root);
	}

	/** A locked registry version an upgrade removed is picked again within the range, unless the resolution is strict. */
	static function testRegistryRepick():Void {
		var root = temporaryDirectory("registry-repick"),
			registry = Path.join([root, "registry"]),
			app = Path.join([root, "app"]),
			foo = Path.join([registry, "foo", "1.1.0"]);
		writePackage(foo, '{"package":{"name":"foo"}}', []);
		File.saveContent(Path.join([foo, ".haxeon-checksum"]), "new\n");
		File.saveContent(Path.join([registry, "index.json"]),
			'{"version":1,"packages":{"foo":{"versions":[{"version":"1.1.0","checksum":"new"}]}}}\n');
		writePackage(app, '{"package":{"name":"app"},"dependencies":{"foo":"^1.0"}}', []);
		var manifest = Path.join([app, "haxeon.json"]),
			resolver = new PackageResolver(new RegistrySourceAcquirer(Path.join([root, "cache"]), registry)),
			current = resolver.resolve(manifest).lockfile,
			old = new PackageLockfile([
				for (entry in current.entries)
					entry.id.name == "foo" ? new PackageLockEntry(entry.id, entry.source, "1.0.0", "old",
					entry.dependencies) : entry
			]);
		expect(resolver.resolve(manifest, old, true).lockfile.get("foo").resolvedRevision == "1.1.0",
			"a locked registry version that is gone should be picked again within the range");
		expectThrows(() -> resolver.resolve(manifest, old, true, null, null, true),
			"a strict resolution should refuse a locked registry version that is gone");
		FileTree.remove(root);
	}

	/** `[patch.haxeon]` resolves a registry dependency from a directory, without changing the dependency. */
	static function testRegistryPatch():Void {
		var root = temporaryDirectory("registry-patch"),
			app = Path.join([root, "app"]),
			local = Path.join([root, "local-foo"]);
		writePackage(local, '{"package":{"name":"foo"}}', ["src/Foo.hx"]);
		ensureDirectory(Path.join([app, "src"]));
		File.saveContent(Path.join([app, "haxeon.toml"]),
			'[package]\nname = "app"\n\n[dependencies]\nfoo = "^1.0"\n\n[patch.haxeon]\nfoo = { path = "../local-foo" }\n');
		var project = new PackageResolver(new ProjectSourceAcquirer(Path.join([root, "cache"]), null,
			Path.join([root, "registry"]))).resolve(Path.join([
				app,
				"haxeon.toml"
			]));
		expect(project.packages.get("foo") != null && project.packages.get("foo").root == FileSystem.fullPath(local),
			"[patch.haxeon] should resolve the package from its directory");
		FileTree.remove(root);
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
		FileTree.remove(root);
	}

	static function testAlternateRootManifest():Void {
		var root = temporaryDirectory("alternate-root-manifest"),
			app = Path.join([root, "app"]),
			alternate = Path.join([app, "test.haxeon.json"]);
		writePackage(app, '{"package":{"name":"app"},"entry":"app.Main"}', ["src/Main.hx"]);
		File.saveContent(alternate, '{"package":{"name":"app"},"entry":"app.TestMain","sourceRoots":["src"]}\n');
		var project = new PackageResolver(new PathSourceAcquirer()).resolve(alternate);
		expect(project.manifestPath == FileSystem.fullPath(alternate)
			&& project.manifest.entry == "app.TestMain"
			&& project.rootPackage.manifest.entry == "app.TestMain",
			"the requested root manifest must define the root package and build entry");
		FileTree.remove(root);
	}

	static function testLockfileRoundTrip():Void {
		var lock = new PackageLockfile([
			new PackageLockEntry(new project.PackageId("app"), project.PackageSource.Path("."), null, null,
				[new project.PackageId("foo")]),
			new PackageLockEntry(new project.PackageId("foo"),
				project.PackageSource.Git("https://example.invalid/foo.git", "main"),
				"0123456789012345678901234567890123456789")
		]),
			parsed = PackageLockfile.parse("haxeon.lock", lock.toJson());
		lock.validateGraph(parsed);
		expect(parsed.get("foo").resolvedRevision == "0123456789012345678901234567890123456789"
			&& switch parsed.get("foo").resolvedSource() {
				case project.PackageSource.Git(_, revision): revision == parsed.get("foo").resolvedRevision;
				case _: false;
			}, "lockfiles should round-trip immutable Git revisions and dependency edges");
	}

	static function action(id:String, dependencies:Array<ActionId>, description:String,
			invoke:Void->Int):ExecutionAction
		return new ExecutionAction(new ActionId(id), dependencies, [], [], description,
			Compiler("test-compiler", [description], Sys.getCwd(), new Map(), invoke));

	static function temporaryDirectory(name:String):String {
		var base = Sys.getEnv("TMPDIR");
		if (base == null || base == "")
			base = Sys.getEnv("TEMP");
		if (base == null || base == "")
			base = ".";
		// The epoch in milliseconds does not fit in an Int, so the timestamp stays a Float; a stale directory
		// left by an interrupted run is removed rather than making createDirectory fail.
		var path = Path.join([base, 'haxeon-build-$name-${Std.string(Date.now().getTime())}']);
		FileTree.remove(path);
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

	static function compilerAction(plan:ExecutionPlan):Null<ExecutionAction> {
		for (action in plan.actions)
			switch action.action {
				case Compiler(_, _, _, _, _):
					return action;
				default:
			}
		return null;
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

	public function acquire(source:project.PackageSource, ownerRoot:String,
			packageId:project.PackageId):project.AcquiredSource {
		calls++;
		return delegate.acquire(source, ownerRoot, packageId);
	}
}
