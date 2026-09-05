import compiler.Diagnostic.CompileError;
import compiler.hl.HlWriter;
import compiler.hl.HlPatchReader;
import compiler.hl.HlPatchWriter;
import compiler.hl.HlRuntimeIdentity;
import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlOpcode;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.modules.Compiler;
import compiler.modules.Compiler.CompileResult;
import compiler.modules.CompilerPublication.ReconnectDecision;
import compiler.ir.IrFunctionStateCodec;
import compiler.hl.HlFunctionCacheStateCodec;
import compiler.hl.HlSymbolStateCodec;
import compiler.hl.HlAssemblerStateCodec;
import compiler.hl.HlModuleAssembler;
import compiler.abi.PatchPlanner.PatchDecision;
import runtime.Runtime;
import runtime.LoadedModule;
import runtime.RuntimeError;
import runtime.RuntimeStatus;
import runtime.PatchSet;

class HotReloadMain {
	static function main():Void {
		testPatchContract();
		testDecodedIrLifetime();
		testBackendStateLifetime();
		testLiveAbiPatchMatrix();
		testRetainedPatchedClosure();
		testRetainedObject();
		testCompilerRestart();
		var compiler = new Compiler();
		compiler.update("Value.hx", "function value():Int { return 42; }");
		compiler.update("Probe.hx", "function read():Int { return Value.value(); }");
		compiler.update("Worker.hx",
			"function fib(n:Int):Int { if (n <= 1) return n; return fib(n - 1) + fib(n - 2); } function run():Int { return fib(38); }");
		compiler.update("Seed.hx", "function ratio():Float { return 1.0 + 0.5; } function label():String { return \"initial\"; }");
		compiler.update("ExceptionProbe.hx",
			"function probe():Int { try { throw \"probe\"; } catch (error:Int) { return 0; } catch (error:String) { return 41; } }");
		compiler.update("Main.hx", "function main():Int { return Probe.read() + ExceptionProbe.probe() - 41; }");
		var initial = compiler.compile("Main");
		var liveRevision = initial.revision;

		var valueIndex = initial.functionIds.get("Value.value"),
			readIndex = initial.functionIds.get("Probe.read"),
			exceptionIndex = initial.functionIds.get("ExceptionProbe.probe"),
			workIndex = initial.functionIds.get("Worker.run");
		var loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		if (Runtime.callInt(loaded, valueIndex) != 42)
			throw "initial generation did not return 42";
		if (Runtime.callInt(loaded, readIndex) != 42)
			throw "initial internal call did not return 42";
		if (Runtime.callInt(loaded, exceptionIndex) != 41)
			throw "initial exception handler returned the wrong value";

		compiler.update("Value.hx",
			"function value():Int { var ratio:Float = 2.75; var label:String = \"patched source\"; var result = 0; while (result < 43) { result = result + 1; } return result * 2 / 2; }");
		var changed = compiler.compile("Main");
		var decoded = HlPatchReader.decode(changed.patchBytes);
		if (decoded.moduleId.compare(initial.runtimeIdentity.sub(4, 16)) != 0)
			throw "HLP module identity does not match its load manifest";
		if (decoded.baseInts != initial.module.ints.length || decoded.ints.indexOf(43) < 0)
			throw "HLP did not encode the integer symbol delta";
		if (decoded.baseFloats != initial.module.floats.length || decoded.floats.length != 1 || decoded.floats[0] != 2.75)
			throw "HLP did not encode the source float symbol delta";
		if (decoded.baseStrings != initial.module.strings.length || decoded.strings.indexOf("patched source") < 0)
			throw "HLP did not encode the source string symbol delta";
		var nativeDecoded = Runtime.inspectPatch(changed.patchBytes);
		if (nativeDecoded.baseRevision != decoded.baseRevision
			|| nativeDecoded.revision != decoded.revision
			|| nativeDecoded.functionCount != decoded.functions.length)
			throw 'native and Haxe HLP decoders disagree: ${nativeDecoded.baseRevision}/${nativeDecoded.revision}/${nativeDecoded.functionCount} vs ${decoded.baseRevision}/${decoded.revision}/${decoded.functions.length}';
		try {
			Runtime.inspectPatch(changed.patchBytes.sub(0, changed.patchBytes.length - 1));
			throw "native decoder accepted truncated HLP";
		} catch (error:String) {
			if (error != "HashLink rejected the HLP bytes")
				throw error;
		}
		var compilerIndex = changed.functionIds.get("Value.value");
		if (changed.changedFunctions.length != 1 || changed.changedFunctions[0] != compilerIndex)
			throw 'compiler reported unexpected changed functions: ${changed.changedFunctions}';
		var corruptHash = changed.patchBytes.sub(0, changed.patchBytes.length),
			hashPosition = skipIndex(corruptHash, 24);
		corruptHash.set(hashPosition, corruptHash.get(hashPosition) ^ 1);
		try {
			Runtime.patchSet(loaded, new PatchSet(liveRevision, changed.revision, corruptHash, changed.changedFunctions));
			throw "mismatched symbol prefix unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
		}
		Runtime.patchSet(loaded, new PatchSet(liveRevision, changed.revision, changed.patchBytes, changed.changedFunctions));
		liveRevision = changed.revision;
		if (Runtime.patchJitCount(loaded) != 1)
			throw "one-function patch did not JIT exactly one function";
		if (Runtime.callInt(loaded, valueIndex) != 43)
			throw "patched generation did not return 43";
		if (Runtime.callInt(loaded, readIndex) != 43)
			throw "existing caller did not dispatch through the patched slot";
		if (Runtime.retainedCodeAllocationCount(loaded) != 2)
			throw "initial patch retained an unexpected number of code allocations";

		compiler.update("ExceptionProbe.hx",
			"function probe():Int { try { throw \"probe\"; } catch (error:Int) { return 0; } catch (error:String) { return 42; } }");
		var exceptionPatch = compiler.compile("Main"),
			exceptionDecoded = HlPatchReader.decode(exceptionPatch.patchBytes),
			hasTrap = false,
			hasThrow = false,
			hasSafeCast = false,
			hasRethrow = false,
			hasType = false;
		for (fn in exceptionDecoded.functions)
			for (instruction in fn.instructions) {
				if (instruction.opcode == HlOpcode.Trap)
					hasTrap = true;
				if (instruction.opcode == HlOpcode.Throw)
					hasThrow = true;
				if (instruction.opcode == HlOpcode.SafeCast)
					hasSafeCast = true;
				if (instruction.opcode == HlOpcode.Rethrow)
					hasRethrow = true;
				if (instruction.opcode == HlOpcode.Type)
					hasType = true;
			}
		if (!hasTrap || !hasThrow || !hasSafeCast || !hasRethrow || !hasType)
			throw "typed exception HLP omitted trap, throw, type, cast, or rethrow opcodes";
		Runtime.patchSet(loaded, new PatchSet(liveRevision, exceptionPatch.revision, exceptionPatch.patchBytes, exceptionPatch.changedFunctions));
		liveRevision = exceptionPatch.revision;
		if (Runtime.callInt(loaded, exceptionIndex) != 42)
			throw "hot-patched exception handler did not execute";
		var retainedAllocations = Runtime.retainedCodeAllocationCount(loaded);

		for (i in 0...100) {
			var expected = 44 + (i & 1);
			compiler.update("Value.hx", 'function value():Int { return $expected; }');
			var iteration = compiler.compile("Main");
			Runtime.patchSet(loaded, new PatchSet(liveRevision, iteration.revision, iteration.patchBytes, iteration.changedFunctions));
			liveRevision = iteration.revision;
			if (Runtime.callInt(loaded, readIndex) != expected)
				throw 'stress patch $i returned the wrong value';
			if (Runtime.retainedCodeAllocationCount(loaded) != retainedAllocations)
				throw 'stress patch $i leaked a code allocation';
		}

		var beforePair = Runtime.patchJitCount(loaded);
		compiler.update("Value.hx", "function value():Int { return 46; }");
		compiler.update("Probe.hx", "function read():Int { var result = Value.value(); return result; }");
		var pair = compiler.compile("Main");
		if (pair.changedFunctions.length != 2)
			throw "two-function edit did not produce an atomic pair";
		var pairDecoded = HlPatchReader.decode(pair.patchBytes),
			hasRelocation = false;
		for (patchedFunction in pairDecoded.functions)
			if (patchedFunction.relocations.length > 0)
				hasRelocation = true;
		if (!hasRelocation)
			throw "patched calls were not encoded as stable-ID relocations";
		Runtime.patchSet(loaded, new PatchSet(liveRevision, pair.revision, pair.patchBytes, pair.changedFunctions));
		liveRevision = pair.revision;
		if (Runtime.patchJitCount(loaded) - beforePair != 2)
			throw "two-function patch did not JIT exactly two functions";
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
		Runtime.patchSet(loaded, new PatchSet(liveRevision, concurrentPatch.revision, concurrentPatch.patchBytes, concurrentPatch.changedFunctions));
		liveRevision = concurrentPatch.revision;
		if (!finished.wait(5.0) || workerResult != 39088169)
			throw "concurrent call did not finish safely";
		if (Runtime.callInt(loaded, readIndex) != 47)
			throw "concurrent patch was not committed";

		compiler.update("Value.hx", "function value():Int { return 48; }");
		var competingPatch = compiler.compile("Main"), ready = new sys.thread.Lock(), gate = new sys.thread.Lock(), doneA = new sys.thread.Lock(),
			doneB = new sys.thread.Lock(), outcomeA = "", outcomeB = "";
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
				Runtime.patchSet(loaded, new PatchSet(liveRevision, failurePatch.revision, failurePatch.patchBytes, failurePatch.changedFunctions));
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
		Runtime.patchSet(loaded, new PatchSet(liveRevision, failurePatch.revision, failurePatch.patchBytes, failurePatch.changedFunctions));
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
			Runtime.patchSet(loaded, new PatchSet(liveRevision, liveRevision + 1, haxe.io.Bytes.ofString("not HLP"), [valueIndex]));
			throw "malformed patch unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFormat)
				throw error;
		}
		if (Runtime.callInt(loaded, valueIndex) != 49)
			throw "rejected patch damaged the live generation";

		try {
			Runtime.patchSet(loaded, new PatchSet(liveRevision - 1, liveRevision, failurePatch.patchBytes, failurePatch.changedFunctions));
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
			Runtime.patchSet(loaded, new PatchSet(liveRevision, liveRevision + 1, foreignPatch.patchBytes, foreignPatch.changedFunctions));
			throw "foreign-module patch unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
		}
		if (Runtime.callInt(loaded, valueIndex) != 49)
			throw "foreign patch damaged the live generation";
		Runtime.dispose(loaded);
		testAppendedFloatAndStringSymbols();
		testNonMovingTypeArena();
		Sys.println("PASS: selective HLP patches are atomic and retain bounded JIT code");
	}

	static function applyCompetingPatch(loaded:LoadedModule, patch:CompileResult, baseRevision:Int):String {
		try {
			Runtime.patchSet(loaded, new PatchSet(baseRevision, patch.revision, patch.patchBytes, patch.changedFunctions));
			return "ok";
		} catch (error:RuntimeError) {
			return error.status == RuntimeStatus.StalePatch ? "stale" : 'runtime-${error.status}';
		} catch (error:Dynamic) {
			return 'error-$error';
		}
	}

	static function testRetainedObject():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function make():Box { return new Box(40); } function read(box:Box):Int { return box.value; } function main():Int { return read(make()); }");
		var initial = compiler.compile("Main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		var retained = Runtime.retainObject(loaded, initial.functionIds.get("Main.make"));
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function make():Box { return new Box(40); } function read(box:Box):Int { return box.value + 2; } function main():Int { return read(make()); }");
		var changed = compiler.compile("Main");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callIntObject(loaded, initial.functionIds.get("Main.read"), retained) != 42)
			throw "patched code could not consume a retained object with the same layout";
		Runtime.dispose(loaded);
	}

	static function testRetainedPatchedClosure():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "function value():Int { return 40; } function make():() -> Int { return value; } function main():Int { return value(); }");
		var initial = compiler.compile("Main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		var makeId = initial.functionIds.get("Main.make");
		compiler.update("Main.hx",
			"function value():Int { return 41; } function make():() -> Int { var marker = 1; return value; } function main():Int { return value(); }");
		var first = compiler.compile("Main");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, first.revision, first.patchBytes, first.changedFunctions));
		var retained = Runtime.retainClosure(loaded, makeId);
		if (Runtime.callRetainedClosureInt(retained) != 41)
			throw "patched closure did not capture the published function";
		compiler.update("Main.hx",
			"function value():Int { return 42; } function make():() -> Int { var marker = 2; return value; } function main():Int { return value(); }");
		var second = compiler.compile("Main");
		Runtime.patchSet(loaded, new PatchSet(first.revision, second.revision, second.patchBytes, second.changedFunctions));
		if (Runtime.callRetainedClosureInt(retained) != 41)
			throw "replacing patch owners invalidated an escaped closure";
		if (Runtime.retiredCodeAllocationCount(loaded) != 1)
			throw "escaped closure JIT owner was not tracked as retired";
		Runtime.dispose(loaded);
	}

	static function testPatchContract():Void {
		var ids = [7], patch = new PatchSet(1, 2, haxe.io.Bytes.ofString("HLP"), ids);
		ids[0] = 9;
		if (patch.changedFunctions[0] != 7)
			throw "patch contract retained caller-owned function identities";
		try {
			new PatchSet(2, 2, haxe.io.Bytes.ofString("HLP"), [7]);
			throw "patch contract accepted a non-advancing revision";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadArgument)
				throw error;
		}
	}

	static function testLiveAbiPatchMatrix():Void {
		var fixtures = [
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
			var initial = compiler.compile("Main"),
				mainId = initial.functionIds.get("main");
			var loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
			compiler.update("Main.hx", fixture.after);
			var changed = compiler.compile("Main");
			if (changed.requiresReload || changed.patchBytes == null || changed.changedFunctions.length == 0)
				throw '${fixture.name}: compiler did not emit a body patch';
			Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
			if (Runtime.callInt(loaded, mainId) != 42)
				throw '${fixture.name}: live runtime did not execute the patched behavior';
			Runtime.dispose(loaded);
		}
	}

	static function testCompilerRestart():Void {
		var compiler = new Compiler();
		compiler.enablePublicationTracking();
		compiler.update("Main.hx", "function helper():Int { return 1; } function main():Int { return 40 + helper() - 1; }");
		var initial = compiler.compile("Main"),
			mainId = initial.functionIds.get("main"),
			helperId = initial.functionIds.get("Main.helper"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		compiler.acknowledgePublication(initial.revision);
		var state = compiler.exportIdentityState();
		if (state.compare(compiler.exportIdentityState()) != 0)
			throw "Acknowledged compiler state was not deterministic";
		var resumed = new Compiler(state);
		switch resumed.reconcileRuntime(initial.runtimeIdentity.sub(4, 16), initial.revision) {
			case ContinuePatching:
			case ReloadDomain(reason):
				throw 'Restored compiler required reload: $reason';
		}
		resumed.update("Main.hx", "function helper():Int { return 1; } function main():Int { return 42 + helper() - 1; }");
		var changed = resumed.compile("Main");
		if (changed.revision != initial.revision + 1
			|| changed.changedFunctions.length != 1
			|| changed.changedFunctions[0] != mainId
			|| changed.changedFunctions[0] == helperId
			|| changed.patchBytes == null)
			throw "Restarted compiler did not emit one revision-2 body patch";
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		resumed.acknowledgePublication(changed.revision);
		if (Runtime.callInt(loaded, mainId) != 42)
			throw "Surviving runtime did not execute the restarted compiler patch";
		Runtime.dispose(loaded);
	}

	static function testBackendStateLifetime():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "function add(a:Int, b:Int):Int { return a + b; } function main():Int { return add(20, 22); }");
		var program = compiler.compile("Main").ir,
			assembler = new HlModuleAssembler();
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
		var uninterruptedAssembler = assembler.copy(),
			restoredAssembler = HlAssemblerStateCodec.decode(assemblerBytes),
			editedCompiler = new Compiler();
		editedCompiler.update("Main.hx", "function add(a:Int, b:Int):Int { return a + b; } function main():Int { return add(21, 22); }");
		var edited = editedCompiler.compile("Main").ir;
		var uninterrupted = uninterruptedAssembler.assemble(edited, ["main"], Patch),
			restored = restoredAssembler.assemble(edited, ["main"], Patch);
		if (uninterrupted.revision != restored.revision
			|| uninterrupted.baseInts != restored.baseInts
			|| uninterrupted.baseFloats != restored.baseFloats
			|| uninterrupted.baseStrings != restored.baseStrings
			|| uninterrupted.baseTypes != restored.baseTypes
			|| uninterrupted.changedFunctions.join(",") != restored.changedFunctions.join(",")
			|| uninterrupted.changedSlots.join(",") != restored.changedSlots.join(",")
			|| HlWriter.encode(uninterrupted.module).compare(HlWriter.encode(restored.module)) != 0)
			throw "Restored assembler output disagreed with uninterrupted assembly";
		probeCompiler("mutated restored assembler");
	}

	static function probeCompiler(after:String):Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "function main():Int { return 42; }");
		if (compiler.compile("Main").ir.functions.length == 0)
			throw 'Compiler failed after restored $after lifetime stress';
	}

	static function testDecodedIrLifetime():Void {
		for (iteration in 0...100) {
			var compiler = new Compiler();
			compiler.update("Main.hx", 'function add(a:Int, b:Int):Int { return a + b; } function main():Int { return add($iteration, 1); }');
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

	static function testNonMovingTypeArena():Void {
		var moduleId = haxe.io.Bytes.alloc(16);
		moduleId.set(0, 91);
		var code = new HlCode();
		code.ints = [42];
		code.types = [Simple(HlType.Void), Simple(HlType.I32), Function([], 1)];
		code.functions = [new HlFunction(2, 0, [1], [LoadInt(0, 0), Return(0)])];
		code.entryPoint = 0;
		var indices:Map<String, Int> = [],
			ids:Map<String, Int> = [],
			bySlot:Map<Int, Int> = [];
		indices.set("value", 0);
		ids.set("value", 71000);
		bySlot.set(0, 71000);
		var loaded = Runtime.load(HlWriter.encode(code), HlRuntimeIdentity.encode(moduleId, indices, ids));
		var initialCapacity = Runtime.metadataTypeCapacity(loaded);
		if (Runtime.metadataTypeCount(loaded) != code.types.length || initialCapacity - code.types.length != 65536)
			throw "type arena did not expose its fixed append reserve";
		var revision = 1;
		for (i in 0...100) {
			var baseTypes = code.types.length;
			code.types.push(Function([1], 1));
			code.functions = [new HlFunction(2, 0, [1, baseTypes], [LoadInt(0, 0), Return(0)])];
			var patch = HlPatchWriter.encode(code, moduleId, [0], bySlot, revision, revision + 1, 1, 0, 0, baseTypes);
			Runtime.patchSet(loaded, new PatchSet(revision, revision + 1, patch, [71000]));
			revision++;
			if (Runtime.callInt(loaded, 71000) != 42)
				throw 'type arena patch $i damaged the live function';
		}
		var baseTypes = code.types.length;
		code.types.push(Function([999999], 1));
		var invalid = HlPatchWriter.encode(code, moduleId, [0], bySlot, revision, revision + 1, 1, 0, 0, baseTypes);
		try {
			Runtime.patchSet(loaded, new PatchSet(revision, revision + 1, invalid, [71000]));
			throw "invalid appended type unexpectedly succeeded";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
		}
		code.types.pop();
		if (Runtime.metadataTypeCount(loaded) != code.types.length || Runtime.callInt(loaded, 71000) != 42)
			throw "failed type transaction damaged the live module";

		var retainedTypeCount = code.types.length;
		for (_ in retainedTypeCount...initialCapacity + 1)
			code.types.push(Simple(HlType.I32));
		var exhausted = HlPatchWriter.encode(code, moduleId, [0], bySlot, revision, revision + 1, 1, 0, 0, retainedTypeCount);
		try {
			Runtime.patchSet(loaded, new PatchSet(revision, revision + 1, exhausted, [71000]));
			throw "exhausted type arena unexpectedly accepted metadata";
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
		}
		code.types.resize(retainedTypeCount);
		if (Runtime.metadataTypeCount(loaded) != retainedTypeCount
			|| Runtime.metadataTypeCapacity(loaded) != initialCapacity
			|| Runtime.callInt(loaded, 71000) != 42)
			throw "type arena exhaustion was not transactional";

		code.functions = [new HlFunction(2, 0, [1], [LoadInt(0, 0), Return(0)])];
		var recovery = HlPatchWriter.encode(code, moduleId, [0], bySlot, revision, revision + 1, 1, 0, 0, retainedTypeCount);
		Runtime.patchSet(loaded, new PatchSet(revision, revision + 1, recovery, [71000]));
		if (Runtime.callInt(loaded, 71000) != 42)
			throw "valid patch did not recover after type arena exhaustion";
		Runtime.dispose(loaded);
	}

	static function testAppendedFloatAndStringSymbols():Void {
		var moduleId = haxe.io.Bytes.alloc(16);
		moduleId.set(0, 77);
		var code = new HlCode();
		code.ints = [1];
		code.types = [
			Simple(HlType.Void),
			Simple(HlType.I32),
			Simple(HlType.F64),
			Simple(HlType.Bytes),
			Function([], 1)
		];
		code.functions = [new HlFunction(4, 0, [1], [LoadInt(0, 0), Return(0)])];
		code.entryPoint = 0;
		var indices:Map<String, Int> = [],
			ids:Map<String, Int> = [],
			bySlot:Map<Int, Int> = [];
		indices.set("value", 0);
		ids.set("value", 70000);
		bySlot.set(0, 70000);
		var loaded = Runtime.load(HlWriter.encode(code), HlRuntimeIdentity.encode(moduleId, indices, ids));
		code.ints.push(2);
		code.floats.push(3.5);
		code.strings.push("new symbol");
		code.functions = [
			new HlFunction(4, 0, [2, 3, 1], [LoadFloat(0, 0), LoadString(1, 0), LoadInt(2, 1), Return(2)])
		];
		var bytes = HlPatchWriter.encode(code, moduleId, [0], bySlot, 1, 2, 1, 0, 0, 5);
		Runtime.patchSet(loaded, new PatchSet(1, 2, bytes, [70000]));
		if (Runtime.callInt(loaded, 70000) != 2)
			throw "patch using appended float and string symbols returned the wrong value";
		var revision = 2;
		for (i in 0...20) {
			var baseInts = code.ints.length,
				baseFloats = code.floats.length,
				baseStrings = code.strings.length;
			code.ints.push(3 + i);
			code.floats.push(i + 0.25);
			code.strings.push('symbol-$i');
			code.functions = [
				new HlFunction(4, 0, [2, 3, 1], [
					LoadFloat(0, code.floats.length - 1),
					LoadString(1, code.strings.length - 1),
					LoadInt(2, code.ints.length - 1),
					Return(2)
				])
			];
			var patch = HlPatchWriter.encode(code, moduleId, [0], bySlot, revision, revision + 1, baseInts, baseFloats, baseStrings, 5);
			Runtime.patchSet(loaded, new PatchSet(revision, revision + 1, patch, [70000]));
			revision++;
			if (Runtime.callInt(loaded, 70000) != 3 + i)
				throw 'non-integer symbol stress patch $i returned the wrong value';
		}
		if (Runtime.retainedCodeAllocationCount(loaded) != 2)
			throw "non-integer symbol patch retained extra JIT allocations";
		Runtime.dispose(loaded);
	}

	static function skipIndex(bytes:haxe.io.Bytes, position:Int):Int {
		var first = bytes.get(position++);
		if ((first & 0x80) == 0)
			return position;
		return position + ((first & 0x40) == 0 ? 1 : 3);
	}
}
