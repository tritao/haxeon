using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.compilation.CompilerPublication.ReconnectDecision;
import compiler.core.Diagnostic.CompileError;
import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.patch.HlSectionPatch;
import compiler.hl.persistence.HlAssemblerStateCodec;
import compiler.hl.persistence.HlFunctionCacheStateCodec;
import compiler.hl.persistence.HlSymbolStateCodec;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.runtime.CompilerIntrinsics;
import runtime.LoadedModule;
import runtime.ModuleRetirementStatus.ModuleRetirementFlag;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimeError;
import runtime.RuntimeStatus;
import sys.FileSystem;
import sys.io.File;

class HotReloadMain {
	static function main():Void {
		testPatchContract();
		testDecodedIrLifetime();
		testBackendStateLifetime();
		testJitSupportModuleRetirement();
		testLiveAbiPatchMatrix();
		testLiveReachability();
		testLivePrunedReach();
		testRetainedPatchedClosure();
		if (Runtime.retryRetirements() != 0)
			throw "released closure kept module retirement blocked after its frame unwound";
		testRetainedObject();
		if (Runtime.retryRetirements() != 0)
			throw "released object kept module retirement blocked after its frame unwound";
		testPhysicalModuleReclamation();
		testFailedInitializerRetirement();
		testCompilerRestart();
		var compiler = new Compiler();
		compiler.update("Value.hx", "function value():Int { return 42; }");
		compiler.update("Probe.hx", "function read():Int { return Value.value(); }");
		compiler.update("Worker.hx",
			"function fib(n:Int):Int { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } function run():Int { return fib(38); }");
		compiler.update("Seed.hx",
			"function ratio():Float { return 1.0 + 0.5; } function label():String { return \"initial\"; }");
		compiler.update("ExceptionProbe.hx",
			"function probe():Int { try { throw \"probe\"; } catch (error:Int) { return 0; } catch (error:String) { return 41; } }");
		compiler.update("Main.hx",
			"function main():Int { var result = Probe.read() + ExceptionProbe.probe() - 41; if (result < 0) return Worker.run(); return result; }");
		var initial = compiler.compile("Main");
		var liveRevision = initial.revision;

		var loaded = Runtime.load(initial.artifact.hashLink().hashLinkBytes().flatten(),
			initial.artifact.hashLink().runtimeIdentity);
		var valueIndex = Runtime.requireFunctionId(loaded, "Value.value"),
			readIndex = Runtime.requireFunctionId(loaded, "Probe.read"),
			exceptionIndex = Runtime.requireFunctionId(loaded, "ExceptionProbe.probe"),
			workIndex = Runtime.requireFunctionId(loaded, "Worker.run");
		if (Runtime.callInt(loaded, valueIndex) != 42)
			throw "initial generation did not return 42";
		var initialLocation = Runtime.jitLocation(loaded, valueIndex);
		if (initialLocation == null
			|| initialLocation.indexOf("Value.value") < 0
			|| initialLocation.indexOf("function=") < 0
			|| initialLocation.indexOf(" opcode=") < 0)
			throw 'initial JIT target did not resolve to a function/opcode location: $initialLocation';
		if (Runtime.callInt(loaded, readIndex) != 42)
			throw "initial internal call did not return 42";
		if (Runtime.callInt(loaded, exceptionIndex) != 41)
			throw "initial exception handler returned the wrong value";

		compiler.update("Value.hx",
			"function value():Int { var ratio:Float = 2.75; var label:String = \"patched source\"; var result = 0; while (result < 43) { result = result + 1; } return (result * 2) >> 1; }");
		var changed = compiler.compile("Main");
		var decoded = HlSectionPatch.decode(changed.artifact.hashLink().patchBytes);
		if (decoded.moduleId.compare(initial.artifact.hashLink().runtimeIdentity.sub(4, 16)) != 0)
			throw "HLP module identity does not match its load manifest";
		// Value.value and the two callers that inlined it, each in its home's section: `main` is named after no declaration.
		var replaced = [for (section in decoded.content.replaced) section.path];
		if (replaced.join(",") != "Probe,Value,$shared" || decoded.content.removed.length != 0)
			throw 'HLP did not replace exactly the sections of the edited function and its inlining callers: $replaced';
		var nativeDecoded = Runtime.inspectPatch(changed.artifact.hashLink().patchBytes);
		if (nativeDecoded.baseRevision != decoded.baseRevision || nativeDecoded.revision != decoded.revision)
			throw 'native and Haxe HLP decoders disagree: ${nativeDecoded.baseRevision}/${nativeDecoded.revision} vs ${decoded.baseRevision}/${decoded.revision}';
		try {
			Runtime.inspectPatch(changed.artifact.hashLink().patchBytes.sub(0,
				changed.artifact.hashLink().patchBytes.length - 1));
			throw "native decoder accepted truncated HLP";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFormat)
				throw error;
		}
		// Inlined callers also need regeneration when Value.value changes.
		if (changed.changedFunctions.join(",") != "Probe.read,Value.value,main")
			throw 'compiler reported unexpected changed functions: ${changed.changedFunctions}';
		// A section the loader cannot read refuses the whole patch, which leaves the module as it was.
		var unreadable = decoded.content.replaced[0].bytes.sub(0, decoded.content.replaced[0].bytes.length);
		unreadable.set(0, 9);
		var corrupt = HlSectionPatch.encode(decoded.moduleId, decoded.baseRevision, decoded.revision, {
			replaced: [{path: decoded.content.replaced[0].path, bytes: unreadable}],
			removed: [],
			renames: [],
			guards: [],
			migrations: []
		});
		try {
			Runtime.patchSet(loaded, new PatchSet(liveRevision, changed.revision, corrupt, changed.changedFunctions));
			throw "a patch with an unreadable section unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
		}
		Runtime.patchSet(loaded,
			new PatchSet(liveRevision, changed.revision, changed.artifact.hashLink().patchBytes,
			changed.changedFunctions));
		liveRevision = changed.revision;
		if (Runtime.patchJitCount(loaded) != changed.changedFunctions.length)
			throw "one-function patch did not JIT exactly one function";
		if (Runtime.callInt(loaded, valueIndex) != 43)
			throw "patched generation did not return 43";
		var patchedLocation = Runtime.jitLocation(loaded, valueIndex);
		if (patchedLocation == null
			|| patchedLocation.indexOf("Value.value") < 0
			|| patchedLocation.indexOf("function=") < 0
			|| patchedLocation.indexOf(" opcode=") < 0)
			throw 'patched JIT target did not resolve to a function/opcode location: $patchedLocation';
		if (Runtime.debugRegionCount(loaded) != 1)
			throw "HLD3 registry did not publish the active patch JIT region";
		if (Runtime.callInt(loaded, readIndex) != 43)
			throw "existing caller did not dispatch through the patched slot";
		if (Runtime.retainedCodeAllocationCount(loaded) != 2)
			throw "initial patch retained an unexpected number of code allocations";

		compiler.update("ExceptionProbe.hx",
			"function probe():Int { try { throw \"probe\"; } catch (error:Int) { return 0; } catch (error:String) { return 42; } }");
		var exceptionPatch = compiler.compile("Main"),
			exceptionModule = exceptionPatch.artifact.hashLink().module,
			hasTrap = false,
			hasThrow = false,
			hasSafeCast = false,
			hasRethrow = false,
			hasType = false;
		if ([for (section in HlSectionPatch.decode(exceptionPatch.artifact.hashLink().patchBytes).content.replaced)
			section.path]
			.indexOf("ExceptionProbe") < 0)
			throw "typed exception HLP did not replace the edited section";
		for (instruction in exceptionModule.functions[exceptionModule.functionNames.indexOf("ExceptionProbe.probe")]
			.opcodes)
			switch instruction {
				case Trap(_, _, _): hasTrap = true;
				case Throw(_): hasThrow = true;
				case SafeCast(_, _): hasSafeCast = true;
				case Rethrow(_): hasRethrow = true;
				case LoadType(_, _): hasType = true;
				default:
			}
		if (!hasTrap || !hasThrow || !hasSafeCast || !hasRethrow || !hasType)
			throw "typed exception HLP omitted trap, throw, type, cast, or rethrow opcodes";
		Runtime.patchSet(loaded,
			new PatchSet(liveRevision, exceptionPatch.revision, exceptionPatch.artifact.hashLink().patchBytes,
			exceptionPatch.changedFunctions));
		liveRevision = exceptionPatch.revision;
		if (Runtime.callInt(loaded, exceptionIndex) != 42)
			throw "hot-patched exception handler did not execute";
		var retainedAllocations = Runtime.retainedCodeAllocationCount(loaded);

		for (i in 0...100) {
			var expected = 44 + (i & 1);
			compiler.update("Value.hx", 'function value():Int { return $expected; }');
			var iteration = compiler.compile("Main");
			Runtime.patchSet(loaded,
				new PatchSet(liveRevision, iteration.revision, iteration.artifact.hashLink().patchBytes,
				iteration.changedFunctions));
			liveRevision = iteration.revision;
			if (Runtime.callInt(loaded, readIndex) != expected)
				throw 'stress patch $i returned the wrong value';
			if (Runtime.retainedCodeAllocationCount(loaded) != retainedAllocations)
				throw 'stress patch $i leaked a code allocation';
			if (Runtime.retiredCodeAllocationCount(loaded) != 0)
				throw 'stress patch $i retained superseded JIT code';
		}

		var beforePair = Runtime.patchJitCount(loaded);
		compiler.update("Value.hx", "function value():Int { return 46; }");
		compiler.update("Probe.hx", "function read():Int { var result = Value.value(); return result; }");
		var pair = compiler.compile("Main");
		if (pair.changedFunctions.join(",") != "Probe.read,Value.value,main")
			throw "two-function edit did not produce an atomic pair";
		Runtime.patchSet(loaded,
			new PatchSet(liveRevision, pair.revision, pair.artifact.hashLink().patchBytes, pair.changedFunctions));
		liveRevision = pair.revision;
		if (Runtime.patchJitCount(loaded) - beforePair != pair.changedFunctions.length)
			throw "patch did not JIT exactly the edited functions and their inlined caller";
		if (Runtime.callInt(loaded, readIndex) != 46)
			throw "two-function patch was not committed together";

		var started = new sys.thread.Lock(), finished = new sys.thread.Lock();
		var workerResult = 0;
		sys.thread.Thread.create(function() {
			started.release();
			workerResult = Runtime.callInt(loaded, workIndex);
			finished.release();
		});
		started.wait();
		Sys.sleep(0.01);
		compiler.update("Value.hx", "function value():Int { return 47; }");
		var concurrentPatch = compiler.compile("Main");
		Runtime.patchSet(loaded,
			new PatchSet(liveRevision, concurrentPatch.revision, concurrentPatch.artifact.hashLink().patchBytes,
			concurrentPatch.changedFunctions));
		liveRevision = concurrentPatch.revision;
		if (!finished.wait(5.0) || workerResult != 39088169)
			throw "concurrent call did not finish safely";
		if (Runtime.callInt(loaded, readIndex) != 47)
			throw "concurrent patch was not committed";

		compiler.update("Value.hx", "function value():Int { return 48; }");
		var competingPatch = compiler.compile("Main"),
			ready = new sys.thread.Lock(),
			gate = new sys.thread.Lock(),
			doneA = new sys.thread.Lock(),
			doneB = new sys.thread.Lock(),
			outcomeA = "",
			outcomeB = "";
		sys.thread.Thread.create(function() {
			ready.release();
			gate.wait();
			outcomeA = applyCompetingPatch(loaded, competingPatch, liveRevision);
			doneA.release();
		});
		sys.thread.Thread.create(function() {
			ready.release();
			gate.wait();
			outcomeB = applyCompetingPatch(loaded, competingPatch, liveRevision);
			doneB.release();
		});
		ready.wait();
		ready.wait();
		gate.release();
		gate.release();
		if (!doneA.wait(5.0) || !doneB.wait(5.0))
			throw "competing patch workers did not finish";
		if (!((outcomeA == "ok" && outcomeB == "stale") || (outcomeA == "stale" && outcomeB == "ok")))
			throw 'competing patches produced incoherent outcomes: $outcomeA/$outcomeB';
		liveRevision = competingPatch.revision;
		if (Runtime.liveRevision(loaded) != liveRevision || Runtime.callInt(loaded, readIndex) != 48)
			throw "competing patch publication was not atomic";

		compiler.update("Value.hx", "function value():Int { return 49; }");
		var failurePatch = compiler.compile("Main"),
			beforeFailureTypes = Runtime.metadataTypeCount(loaded),
			beforeFailureCapacity = Runtime.metadataTypeCapacity(loaded),
			beforeFailureAllocations = Runtime.retainedCodeAllocationCount(loaded);
		for (stage in 1...4) {
			Runtime.injectPatchFailure(loaded, stage);
			try {
				Runtime.patchSet(loaded,
					new PatchSet(liveRevision, failurePatch.revision, failurePatch.artifact.hashLink().patchBytes,
					failurePatch.changedFunctions));
				throw 'injected patch failure $stage unexpectedly succeeded';
			} catch (error:RuntimeError) {
				if (error.status != RuntimeStatus.Incompatible)
					throw error;
			}
			if (Runtime.liveRevision(loaded) != liveRevision
				|| Runtime.metadataTypeCount(loaded) != beforeFailureTypes
				|| Runtime.metadataTypeCapacity(loaded) != beforeFailureCapacity
				|| Runtime.retainedCodeAllocationCount(loaded) != beforeFailureAllocations
				|| Runtime.callInt(loaded, readIndex) != 48)
				throw 'injected patch failure $stage changed published state';
		}
		Runtime.patchSet(loaded,
			new PatchSet(liveRevision, failurePatch.revision, failurePatch.artifact.hashLink().patchBytes,
			failurePatch.changedFunctions));
		liveRevision = failurePatch.revision;
		if (Runtime.liveRevision(loaded) != liveRevision || Runtime.callInt(loaded, readIndex) != 49)
			throw "patch did not recover after injected staging failures";

		compiler.update("Value.hx", 'function value():Bool { return true; }');
		try {
			compiler.compile("Main");
			throw "incompatible source unexpectedly compiled";
		} catch (error:CompileError) {}
		if (Runtime.callInt(loaded, valueIndex) != 49)
			throw "compile failure damaged the live generation";

		try {
			Runtime.patchSet(loaded,
				new PatchSet(liveRevision, liveRevision + 1, haxe.io.Bytes.ofString("not HLP"), ["Value.value"]));
			throw "malformed patch unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFormat)
				throw error;
		}
		if (Runtime.callInt(loaded, valueIndex) != 49)
			throw "rejected patch damaged the live generation";

		try {
			Runtime.patchSet(loaded,
				new PatchSet(liveRevision - 1, liveRevision, failurePatch.artifact.hashLink().patchBytes,
				failurePatch.changedFunctions));
			throw "stale patch unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.StalePatch)
				throw error;
		}
		if (Runtime.callInt(loaded, valueIndex) != 49)
			throw "stale patch damaged the live generation";

		var foreign = new Compiler();
		foreign.update("Value.hx", "function value():Int { return 47; }");
		foreign.update("Probe.hx", "function read():Int { return Value.value(); }");
		foreign.update("Main.hx", "function main():Int { return Probe.read(); }");
		foreign.compile("Main");
		foreign.update("Value.hx", "function value():Int { return 99; }");
		var foreignPatch = foreign.compile("Main");
		try {
			Runtime.patchSet(loaded,
				new PatchSet(liveRevision, liveRevision + 1, foreignPatch.artifact.hashLink().patchBytes,
				foreignPatch.changedFunctions));
			throw "foreign-module patch unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
		}
		if (Runtime.callInt(loaded, valueIndex) != 49)
			throw "foreign patch damaged the live generation";
		try {
			Runtime.callString(loaded, valueIndex);
			throw "runtime accepted a call with the wrong result shape";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFunction)
				throw error;
		}
		try {
			Runtime.callInt(loaded, 0x6FFFFFFF);
			throw "runtime accepted an unknown stable function ID";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFunction)
				throw error;
		}
		Runtime.dispose(loaded);
		Runtime.dispose(loaded);
		try {
			Runtime.liveRevision(loaded);
			throw "disposed runtime module remained callable";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadArgument)
				throw error;
		}
		testAppendedFloatAndStringSymbols();
		testNonMovingTypeArena();
		Sys.println("PASS: selective HLP patches are atomic and retain bounded JIT code");
	}

	static function applyCompetingPatch(loaded:LoadedModule, patch:CompileResult, baseRevision:Int):String {
		try {
			Runtime.patchSet(loaded,
				new PatchSet(baseRevision, patch.revision, patch.artifact.hashLink().patchBytes,
				patch.changedFunctions));
			return "ok";
		} catch (error:RuntimeError) {
			return error.status == RuntimeStatus.StalePatch ? "stale" : 'runtime-${error.status}';
		} catch (error:Dynamic) {
			return 'error-$error';
		}
		Runtime.drainRetirements();
		if (Runtime.pendingRetirementCount != 0)
			throw "retirement backlog metric remained nonzero after drain";
	}

	static function testRetainedObject():Void {
		var compiler = new Compiler();
		// The test calls `fail` as a host does, by name: nothing in the program reaches it.
		compiler.setExportedFunctions(["Main.fail"]);
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function make():Box { return new Box(40); } function read(box:Box):Int { return box.value; } function fail():Int { throw new Box(1); } function main():Int { return read(make()); }");
		var initial = compiler.compile("Main"),
			loaded = Runtime.load(initial.artifact.hashLink().hashLinkBytes().flatten(),
				initial.artifact.hashLink().runtimeIdentity);
		var retained = Runtime.retainObject(loaded, Runtime.requireFunctionId(loaded, "Main.make"));
		var retirement = Runtime.retirementStatus(loaded);
		if (retirement.ownedNativeRoots == 0 || !retirement.has(OwnedNativeRoots))
			throw "loaded module globals were not attributed to their native owner";
		if (retirement.liveManagedAllocations == 0 || !retirement.has(LiveManagedAllocations))
			throw "retained object was not attributed to its module";
		if (!retirement.hasKnownBorrowers())
			throw "retirement status did not report the retained object borrower";
		if (retirement.registryReaders != 0 || retirement.has(RegistryReaders))
			throw "retirement status leaked an inactive registry reader";
		try {
			Runtime.callInt(loaded, Runtime.requireFunctionId(loaded, "Main.fail"));
			throw "module exception unexpectedly returned";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Exception)
				throw error;
		}
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function make():Box { return new Box(40); } function read(box:Box):Int { return box.value + 2; } function fail():Int { throw new Box(1); } function main():Int { return read(make()); }");
		var changed = compiler.compile("Main");
		Runtime.patchSet(loaded,
			new PatchSet(initial.revision, changed.revision, changed.artifact.hashLink().patchBytes,
			changed.changedFunctions));
		if (Runtime.callIntObject(loaded, Runtime.requireFunctionId(loaded, "Main.read"), retained) != 42)
			throw "patched code could not consume a retained object with the same layout";
		retained.release();
		Runtime.dispose(loaded);
	}

	static function testRetainedPatchedClosure():Void {
		var compiler = new Compiler();
		// The test calls `make` as a host does, by name: nothing in the program reaches it.
		compiler.setExportedFunctions(["Main.make"]);
		compiler.update("Main.hx",
			"function value():Int { return 40; } function make():() -> Int { return value; } function main():Int { return value(); }");
		var initial = compiler.compile("Main"),
			loaded = Runtime.load(initial.artifact.hashLink().hashLinkBytes().flatten(),
				initial.artifact.hashLink().runtimeIdentity);
		var makeId = Runtime.requireFunctionId(loaded, "Main.make");
		var initialClosure = Runtime.retainClosure(loaded, makeId);
		if (Runtime.callRetainedClosureInt(initialClosure) != 40)
			throw "initial static closure returned the wrong value";
		compiler.update("Main.hx",
			"function value():Int { return 41; } function make():() -> Int { var marker = 1; return value; } function main():Int { return value(); }");
		var first = compiler.compile("Main");
		Runtime.patchSet(loaded,
			new PatchSet(initial.revision, first.revision, first.artifact.hashLink().patchBytes,
			first.changedFunctions));
		if (Runtime.callRetainedClosureInt(initialClosure) != 41)
			throw "initial static closure did not follow its stable function slot";
		var retained = Runtime.retainClosure(loaded, makeId);
		if (Runtime.liveAllocationCount(loaded) == 0)
			throw "retained closure was not attributed to its module";
		if (Runtime.callRetainedClosureInt(retained) != 41)
			throw "patched closure did not capture the published function";
		compiler.update("Main.hx",
			"function value():Int { return 42; } function make():() -> Int { var marker = 2; return value; } function main():Int { return value(); }");
		var second = compiler.compile("Main");
		Runtime.patchSet(loaded,
			new PatchSet(first.revision, second.revision, second.artifact.hashLink().patchBytes,
			second.changedFunctions));
		if (Runtime.callRetainedClosureInt(initialClosure) != 42 || Runtime.callRetainedClosureInt(retained) != 42)
			throw "retained closure did not follow its stable function slot";
		if (Runtime.retiredCodeAllocationCount(loaded) != 0)
			throw "stable closure dispatch retained superseded JIT code";
		Runtime.dispose(loaded);
		if (Runtime.callRetainedClosureInt(initialClosure) != 42 || Runtime.callRetainedClosureInt(retained) != 42)
			throw "module disposal invalidated a retained closure";
		initialClosure.release();
		retained.release();
		Runtime.dispose(loaded);
	}

	static function testJitSupportModuleRetirement():Void {
		var owner = new Compiler();
		owner.update("Main.hx", "function main():Int { return 41; }");
		var ownerResult = owner.compile("Main");
		var survivor = new Compiler();
		survivor.update("Main.hx", "function main():Int { return 42; }");
		var survivorResult = survivor.compile("Main");
		var tmp = Sys.getEnv("TMPDIR"),
			directory = (tmp == null || tmp == "" ? "/tmp" : tmp)
				+ "/haxeon-jit-support-lifetime-"
				+ Std.int(Sys.time() * 1000)
				+ "-"
				+ Std.random(1000000);
		FileSystem.createDirectory(directory);
		var prefix = directory + "/jit-support-lifetime";
		File.saveBytes(prefix + "-owner.hl", ownerResult.artifact.hashLink().hashLinkBytes().flatten());
		File.saveBytes(prefix + "-owner.hli", ownerResult.artifact.hashLink().runtimeIdentity);
		File.saveBytes(prefix + "-survivor.hl", survivorResult.artifact.hashLink().hashLinkBytes().flatten());
		File.saveBytes(prefix + "-survivor.hli", survivorResult.artifact.hashLink().runtimeIdentity);
		var test = Sys.getEnv("HAXEON_SDK") + "/bin/haxeon-jit-support-lifetime";
		#if windows
		test += ".exe";
		#end
		var status = Sys.command(test, [prefix + "-owner", prefix + "-survivor"]);
		for (name in FileSystem.readDirectory(directory))
			FileSystem.deleteFile(directory + "/" + name);
		FileSystem.deleteDirectory(directory);
		if (status != 0)
			throw 'JIT support trampoline did not survive owner-module retirement (exit $status)';
	}

	static function testPhysicalModuleReclamation():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "function main():Int { return 42; }");
		var result = compiler.compile("Main"),
			bytes = result.artifact.hashLink().hashLinkBytes().flatten(),
			identity = result.artifact.hashLink().runtimeIdentity;
		for (i in 0...100) {
			runDisposableGeneration(bytes, identity);
			if (Runtime.retryRetirements() != 0)
				throw 'physical module retirement remained blocked at iteration $i';
		}
	}

	static function runDisposableGeneration(bytes:haxe.io.Bytes, identity:haxe.io.Bytes):Void {
		var loaded = Runtime.load(bytes, identity);
		if (Runtime.callInt(loaded, Runtime.requireFunctionId(loaded, "main")) != 42)
			throw "disposable generation returned the wrong value";
		Runtime.dispose(loaded);
	}

	static function testFailedInitializerRetirement():Void {
		produceFailedInitializer();
		Runtime.drainRetirements();
		if (Runtime.pendingRetirementCount != 0)
			throw "failed initializer lost or retained its internally owned module";
	}

	static function produceFailedInitializer():Void {
		var moduleId = haxe.io.Bytes.alloc(16), code = new HlCode();
		moduleId.set(0, 37);
		code.types = [Simple(HlType.Void), Simple(HlType.Dyn), Function([], 0)];
		code.functions = [new HlFunction(2, 0, [1], [LoadNull(0), Throw(0)])];
		code.entryPoint = 0;
		// The identity names the initializer `__init`.
		var identity = compiler.hl.persistence.HlRuntimeIdentity.encode(moduleId, 1, true);
		code.functionNames = ["other"];
		try {
			Runtime.load(HlWriter.encode(code).flatten(), identity);
			throw "runtime identity accepted an initializer the module does not have";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFormat)
				throw error;
		}
		// A module whose initializer throws does not load: the runtime retires it once the initializer's frames are gone.
		code.functionNames = ["__init"];
		try {
			Runtime.load(HlWriter.encode(code).flatten(), identity);
			throw "throwing module initializer unexpectedly loaded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFormat)
				throw error;
		}
	}

	static function testPatchContract():Void {
		var names = ["main"], patch = new PatchSet(1, 2, haxe.io.Bytes.ofString("HLP"), names);
		names[0] = "other";
		if (patch.changedFunctions[0] != "main")
			throw "patch contract retained caller-owned function identities";
		try {
			new PatchSet(2, 2, haxe.io.Bytes.ofString("HLP"), ["main"]);
			throw "patch contract accepted a non-advancing revision";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadArgument)
				throw error;
		}
	}

	/**
	 * A live module keeps every function, reachable or not: its host can call any function by id, and an edit that makes a class used
	 * or unused must patch like any other edit and not move the module's layout.
	 */
	static function testLiveReachability():Void {
		var unused =
			"class Spare { public function new() {} public function read():Int { return 40; } public function more():Int { return 2; } } "
			+ "function main():Int { return 42; }",
			used =
				"class Spare { public function new() {} public function read():Int { return 40; } public function more():Int { return 2; } } "
				+ "function main():Int { var s = new Spare(); return s.read() + s.more(); }";
		var compiler = new Compiler();
		compiler.update("Main.hx", unused);
		var first = compiler.compile("Main");
		var loaded = Runtime.load(first.artifact.hashLink().hashLinkBytes().flatten(),
			first.artifact.hashLink().runtimeIdentity);
		if (!first.artifact.hashLink().functionIndices.exists("Spare.read")
			|| !first.artifact.hashLink().functionIndices.exists("Spare.more"))
			throw "a live module must keep the methods of a class nothing uses";
		var step = 0, baseRevision = first.revision;
		for (source in [used, unused, used, unused]) {
			step++;
			compiler.update("Main.hx", source);
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null)
				throw 'step $step: making a class used or unused must patch, not reload: ${[for (reason in changed.reloadReasons) Std.string(reason)]}';
			Runtime.patchSet(loaded,
				new PatchSet(baseRevision, changed.revision, changed.artifact.hashLink().patchBytes,
				changed.changedFunctions));
			baseRevision = changed.revision;
			if (Runtime.callInt(loaded, Runtime.requireFunctionId(loaded, "main")) != 42)
				throw 'step $step: the patched module does not run the edited program';
		}
		Runtime.dispose(loaded);
	}

	/**
	 * A live build prunes as a one-shot build does (docs/design/LIVE_PRUNING.md), and every edit below patches: one that reaches a
	 * function of a loaded standard-library module no code of the module came from, one that first creates a class whose method overrides one (its
	 * slot holds a declaration stub until then), and one after which nothing creates a class the running program holds an
	 * instance of, whose method keeps the code it had.
	 */
	static function testLivePrunedReach():Void {
		// StringTools is loaded from the start, as a module the program imports and does not call.
		var shapes =
			"import StringTools;\nclass Shape { public function new() {} public function area():Int return 1; }\n"
			+ "class Square extends Shape { public function new() super(); override public function area():Int return 4; }\n"
			+ "class Keep { public static var shape:Null<Shape> = null; }\n";
		function program(body:String):String
			return shapes + "function main():Int { " + body + " }";
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		// The test runs in out/.
		compiler.addStandardLibrarySourceRoot("../stdlib");
		compiler.update("Main.hx",
			program("if (Keep.shape == null) Keep.shape = new Shape(); return Keep.shape.area();"));
		var first = compiler.compile("Main"),
			hashLink = first.artifact.hashLink(),
			loaded = Runtime.load(hashLink.hashLinkBytes().flatten(), hashLink.runtimeIdentity),
			main = Runtime.requireFunctionId(loaded, "main"),
			areaSlot = hashLink.functionIndices.get("Shape.area");
		if (hashLink.functionIndices.exists("StringTools.hex"))
			throw "a live build kept a standard-library function nothing calls";
		if (!hashLink.functionIndices.exists("Square.area") || !first.ir.stubbedFunctions.exists("Square.area"))
			throw "a live layout must keep the override of a class nothing creates, as a stub";
		if (Runtime.callInt(loaded, main) != 1)
			throw "the pruned live module does not run";
		var revision = first.revision;
		for (step in [
			{
				label: "reaching StringTools.hex",
				body: "if (Keep.shape == null) Keep.shape = new Shape(); return Keep.shape.area() + StringTools.hex(255).length;",
				expected: 3
			},
			{
				label: "creating Square",
				body: "if (Keep.shape == null) Keep.shape = new Shape(); var square:Shape = new Square(); return Keep.shape.area() + square.area();",
				expected: 5
			},
			{
				label: "no longer creating Shape",
				body: "if (Keep.shape == null) Keep.shape = new Square(); return Keep.shape.area();",
				expected: 1
			}
		]) {
			compiler.update("Main.hx", program(step.body));
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null)
				throw '${step.label}: a reach change must patch, not reload: ${[for (reason in changed.reloadReasons) Std.string(reason)]}';
			if (changed.artifact.hashLink().functionIndices.get("Shape.area") != areaSlot)
				throw '${step.label}: Shape.area moved';
			Runtime.patchSet(loaded,
				new PatchSet(revision, changed.revision, changed.artifact.hashLink().patchBytes,
				changed.changedFunctions));
			revision = changed.revision;
			var actual = Runtime.callInt(loaded, main);
			if (actual != step.expected)
				throw '${step.label}: the patched module returned $actual, not ${step.expected}';
		}
		Runtime.dispose(loaded);
	}

	static function testLiveAbiPatchMatrix():Void {
		var fixtures = [
			{
				name: "enum payload patch operands",
				before: "enum Value { Number(n:Int); } function main():Int { var v = Value.Number(40); return switch v { case Number(n): n; }; }",
				after: "enum Value { Number(n:Int); } function main():Int { var v = Value.Number(42); return switch v { case Number(n): n; }; }"
			},
			{
				name: "integer patch opcodes",
				before: "function main():Int { return 40; }",
				after: "function main():Int { var n = 85; return ((((n % 86) << 1) >> 1) >>> 1) | ((n & 1) ^ 1); }"
			},
			{
				name: "integer to float conversion",
				before: "function main():Int { var n = 40; var f:Float = n; return f == 42.0 ? 42 : 40; }",
				after: "function main():Int { var n = 42; var f:Float = n; return f == 42.0 ? 42 : 40; }"
			},
			{
				name: "null patch operand",
				before: "function main():Int { var s:Null<String> = null; return s == null ? 40 : 0; }",
				after: "function main():Int { var s:Null<String> = null; return s == null ? 42 : 0; }"
			},
			{
				name: "global reads and writes",
				before: "class State { public static var value:Int = 40; } function main():Int { State.value = 40; return State.value; }",
				after: "class State { public static var value:Int = 40; } function main():Int { State.value = 42; return State.value; }"
			},
			{
				name: "top-level body",
				before: "function main():Int { return 40; }",
				after: "function main():Int { return 42; }"
			},
			{
				name: "callee body",
				before: "function value():Int { return 40; } function main():Int { return value(); }",
				after: "function value():Int { return 42; } function main():Int { return value(); }"
			},
			{
				name: "method body",
				before: "class Value { public function read():Int { return 40; } } function main():Int { return new Value().read(); }",
				after: "class Value { public function read():Int { return 42; } } function main():Int { return new Value().read(); }"
			},
			{
				name: "constructor body",
				before: "class Value { public var data:Int; public function new():Void { this.data = 40; } } function main():Int { return new Value().data; }",
				after: "class Value { public var data:Int; public function new():Void { this.data = 42; } } function main():Int { return new Value().data; }"
			},
			{
				name: "fixed-layout closure body",
				before: "function main():Int { var offset = 20; var f = (value:Int) -> { return value + offset; }; return f(20); }",
				after: "function main():Int { var offset = 20; var f = (value:Int) -> { return value + offset + 2; }; return f(20); }"
			}
		];
		for (fixture in fixtures) {
			var compiler = new Compiler();
			compiler.update("Main.hx", fixture.before);
			var initial = compiler.compile("Main");
			var loaded = Runtime.load(initial.artifact.hashLink().hashLinkBytes().flatten(),
				initial.artifact.hashLink().runtimeIdentity),
				mainId = Runtime.requireFunctionId(loaded, "main");
			compiler.update("Main.hx", fixture.after);
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null
				|| changed.changedFunctions.length == 0)
				throw '${fixture.name}: compiler did not emit a body patch';
			Runtime.patchSet(loaded,
				new PatchSet(initial.revision, changed.revision, changed.artifact.hashLink().patchBytes,
				changed.changedFunctions));
			if (Runtime.callInt(loaded, mainId) != 42)
				throw '${fixture.name}: live runtime did not execute the patched behavior';
			Runtime.dispose(loaded);
		}
	}

	static function testCompilerRestart():Void {
		var compiler = new Compiler();
		compiler.enablePublicationTracking();
		compiler.update("Main.hx",
			"function helper():Int { return 1; } function main():Int { return 40 + helper() - 1; }");
		var initial = compiler.compile("Main"),
			loaded = Runtime.load(initial.artifact.hashLink().hashLinkBytes().flatten(),
				initial.artifact.hashLink().runtimeIdentity),
			runningMain = Runtime.requireFunctionId(loaded, "main");
		compiler.acknowledgePublication(initial.revision);
		var state = compiler.exportIdentityState();
		if (state.compare(compiler.exportIdentityState()) != 0)
			throw "Acknowledged compiler state was not deterministic";
		var resumed = new Compiler(state);
		switch resumed.reconcileRuntime(initial.artifact.hashLink().runtimeIdentity.sub(4, 16), initial.revision) {
			case ContinuePatching:
			case ReloadDomain(reason):
				throw 'Restored compiler required reload: $reason';
		}
		resumed.update("Main.hx",
			"function helper():Int { return 1; } function main():Int { return 42 + helper() - 1; }");
		// `helper` is the code it was at the place it was (its positions count from its declaration), so only `main` is patched.
		var changed = resumed.compile("Main");
		if (changed.revision != initial.revision + 1
			|| changed.changedFunctions.length != 1
			|| changed.changedFunctions.indexOf("main") < 0
			|| changed.changedFunctions.indexOf("Main.helper") >= 0
			|| changed.artifact.hashLink().patchBytes == null)
			throw 'Restarted compiler did not emit the revision-2 patch of main alone: ${changed.changedFunctions}';
		Runtime.patchSet(loaded,
			new PatchSet(initial.revision, changed.revision, changed.artifact.hashLink().patchBytes,
			changed.changedFunctions));
		resumed.acknowledgePublication(changed.revision);
		if (Runtime.callInt(loaded, runningMain) != 42)
			throw "Surviving runtime did not execute the restarted compiler patch";
		Runtime.dispose(loaded);
	}

	static function testBackendStateLifetime():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"function add(a:Int, b:Int):Int { return a + b; } function main():Int { return add(20, 22); }");
		var program = compiler.compile("Main").ir,
			assembler = new HlModuleAssembler();
		assembler.livePatching = true;
		assembler.sources = compiler.sourceAnchors();
		assembler.assemble(program, [for (fn in program.functions) fn.name], Patch);
		var cacheBytes = HlFunctionCacheStateCodec.encode(assembler.cache.exportState());
		for (_ in 0...100)
			HlFunctionCacheStateCodec.restore(cacheBytes);
		probeCompiler("function cache");
		var symbolBytes = HlSymbolStateCodec.encode(assembler.symbols.exportState());
		for (_ in 0...100)
			HlSymbolStateCodec.restore(symbolBytes);
		probeCompiler("symbol table");
		var assemblerBytes = HlAssemblerStateCodec.encode(assembler);
		for (_ in 0...100)
			HlAssemblerStateCodec.decode(assemblerBytes);
		probeCompiler("assembler");
		// A baseline of another version has no section digests to patch against, so it does not resume.
		var legacyBytes = assemblerBytes.sub(0, assemblerBytes.length);
		legacyBytes.set(3, 5);
		var legacyRejected = false;
		try
			HlAssemblerStateCodec.decode(legacyBytes)
		catch (error:Dynamic)
			legacyRejected = Std.string(error).indexOf("Unsupported HashLink assembler state version") >= 0;
		if (!legacyRejected)
			throw "An assembler baseline of another version was accepted";
		var uninterruptedAssembler = assembler.copy(),
			restoredAssembler = HlAssemblerStateCodec.decode(assemblerBytes),
			editedCompiler = new Compiler();
		editedCompiler.update("Main.hx",
			"function add(a:Int, b:Int):Int { return a + b; } function main():Int { return add(21, 22); }");
		var edited = editedCompiler.compile("Main").ir;
		// Both functions name the edited source snapshot, including the unchanged body.
		restoredAssembler.livePatching = true;
		uninterruptedAssembler.sources = restoredAssembler.sources = editedCompiler.sourceAnchors();
		var uninterrupted = uninterruptedAssembler.assemble(edited, ["Main.add", "main"], Patch),
			restored = restoredAssembler.assemble(edited, ["Main.add", "main"], Patch);
		if (uninterrupted.revision != restored.revision
			|| uninterrupted.changedFunctions.join(",") != restored.changedFunctions.join(",")
			|| encodedFunctions(uninterrupted.module) != encodedFunctions(restored.module)
			|| Std.string(uninterrupted.module.types) != Std.string(restored.module.types))
			throw "Restored assembler output disagreed with uninterrupted assembly";
		probeCompiler("mutated restored assembler");
	}

	static function encodedFunctions(module:compiler.hl.HlCode):String
		return [for (fn in module.functions) HlWriter.encodeFunction(fn).toHex()].join(",");

	static function probeCompiler(after:String):Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "function main():Int { return 42; }");
		if (compiler.compile("Main").ir.functions.length == 0)
			throw 'Compiler failed after restored $after lifetime stress';
	}

	static function testDecodedIrLifetime():Void {
		for (iteration in 0...100) {
			var compiler = new Compiler();
			compiler.update("Main.hx",
				'function add(a:Int, b:Int):Int { return a + b; } function main():Int { return add($iteration, 1); }');
			var program = compiler.compile("Main").ir, decoded = [];
			for (fn in program.functions)
				decoded.push(IrFunctionStateCodec.decode(IrFunctionStateCodec.encode(fn)));
			IrFunctionStateCodec.verify(decoded, program);
		}
		var probe = new Compiler();
		probe.update("Main.hx", "function main():Int { return 42; }");
		if (probe.compile("Main").ir.functions.length == 0)
			throw "Compiler failed after decoded IR lifetime stress";
	}

	/**
	 * Patches add types into the type table's fixed reserve, so the types loaded code points at never move: the table's capacity
	 * stays what the load gave it while each patch appends a function type.
	 */
	static function testNonMovingTypeArena():Void {
		var compiler = new Compiler();
		function source(arity:Int):String {
			var parameters = [for (index in 0...arity) 'a$index:Int'].join(", "),
				arguments = [for (index in 0...arity) '$index'].join(", ");
			return 'function main():Int { var f = function($parameters):Int { return 42; }; return f($arguments); }';
		}
		compiler.update("Main.hx", source(0));
		var initial = compiler.compile("Main"),
			loaded = Runtime.load(initial.artifact.hashLink().hashLinkBytes().flatten(),
				initial.artifact.hashLink().runtimeIdentity),
			mainId = Runtime.requireFunctionId(loaded, "main"),
			capacity = Runtime.metadataTypeCapacity(loaded),
			types = Runtime.metadataTypeCount(loaded);
		if (capacity - types != 65536)
			throw "type arena did not expose its fixed append reserve";
		var revision = initial.revision;
		for (arity in 1...8) {
			compiler.update("Main.hx", source(arity));
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null)
				throw 'arity $arity: a new function type must patch, not reload';
			Runtime.patchSet(loaded,
				new PatchSet(revision, changed.revision, changed.artifact.hashLink().patchBytes,
				changed.changedFunctions));
			revision = changed.revision;
			if (Runtime.callInt(loaded, mainId) != 42)
				throw 'arity $arity: the type arena patch damaged the live function';
		}
		if (Runtime.metadataTypeCapacity(loaded) != capacity || Runtime.metadataTypeCount(loaded) <= types)
			throw "patches did not append their types into the fixed reserve";
		Runtime.dispose(loaded);
	}

	/** Patches that add Int, Float and String constants extend the running module's tables, edit after edit. */
	static function testAppendedFloatAndStringSymbols():Void {
		var compiler = new Compiler();
		function source(step:Int):String
			return 'function main():Int { var f:Float = ${step}.25; var s = "symbol-$step"; return (f > $step ? $step : 0) + s.length + ${1000 + step}; }';
		compiler.update("Main.hx", source(0));
		var initial = compiler.compile("Main"),
			loaded = Runtime.load(initial.artifact.hashLink().hashLinkBytes().flatten(),
				initial.artifact.hashLink().runtimeIdentity),
			mainId = Runtime.requireFunctionId(loaded, "main"),
			revision = initial.revision;
		for (step in 1...21) {
			compiler.update("Main.hx", source(step));
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.artifact.hashLink().patchBytes == null)
				throw 'step $step: new constants must patch, not reload';
			Runtime.patchSet(loaded,
				new PatchSet(revision, changed.revision, changed.artifact.hashLink().patchBytes,
				changed.changedFunctions));
			revision = changed.revision;
			if (Runtime.callInt(loaded, mainId) != step + 'symbol-$step'.length + 1000 + step)
				throw 'step $step: a patch using appended constants returned the wrong value';
		}
		Runtime.dispose(loaded);
	}
}
