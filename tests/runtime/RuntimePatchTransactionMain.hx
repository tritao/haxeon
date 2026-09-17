import compiler.hl.HlWriter;
import compiler.hl.HlType;
import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.patch.HlPatchReader;
import compiler.hl.patch.HlPatchWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimeError;
import runtime.RuntimeStatus;
import runtime.RuntimePatchTransaction.RuntimePatchTransactionState;
import runtime.RuntimeModuleHandle.RuntimeGcHandle;
#if haxeon
import runtime.hashlink.HlTypeBridge;
#end

class RuntimeGcHandleValue {
	public final value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

class RuntimePatchTransactionMain {
	#if haxeon
	static function testEnumPayloadPatch():Void {
		var compiler = new Compiler();
		compiler.update("EnumMain.hx",
			"enum Value { Number(n:Int); } function main():Int { var value = Value.Number(40); return switch value { case Number(n): n; }; }");
		var initial = compiler.compile("EnumMain"),
			mainId:Int = cast initial.functionIds.get("main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		if (Runtime.callInt(loaded, mainId) != 40)
			throw "Haxe-owned enum runtime did not execute its initial payload";
		compiler.update("EnumMain.hx",
			"enum Value { Number(n:Int); } function main():Int { var value = Value.Number(42); return switch value { case Number(n): n; }; }");
		var changed = compiler.compile("EnumMain");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callInt(loaded, mainId) != 42)
			throw "Haxe-owned enum runtime did not execute its patched payload";
		Runtime.dispose(loaded);
	}

	static function testObjectMethodDispatch():Void {
		var compiler = new Compiler();
		compiler.update("ObjectMain.hx",
			"class Base { public function new() {} public function value():Int return 40; } class Box extends Base { public function new() { super(); } override public function value():Int return 42; } function main():Int { var box:Base = new Box(); return box.value(); }");
		var initial = compiler.compile("ObjectMain"),
			mainId:Int = cast initial.functionIds.get("main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		if (Runtime.callInt(loaded, mainId) != 42)
			throw "Haxe-owned object metadata did not dispatch an instance method";
		compiler.update("ObjectMain.hx",
			"class Base { public function new() {} public function value():Int return 40; } class Box extends Base { public function new() { super(); } override public function value():Int return 43; } function main():Int { var box:Base = new Box(); return box.value(); }");
		var changed = compiler.compile("ObjectMain");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callInt(loaded, mainId) != 43)
			throw "Haxe-owned object metadata did not dispatch a patched instance method";
		Runtime.dispose(loaded);
	}

	static function testInterfaceMethodDispatch():Void {
		var compiler = new Compiler();
		compiler.update("InterfaceMain.hx",
			"interface Value { function value():Int; } class Box implements Value { public function new() {} public function value():Int return 40; } function main():Int { var value:Value = new Box(); return value.value(); }");
		var initial = compiler.compile("InterfaceMain"),
			mainId:Int = cast initial.functionIds.get("main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		if (Runtime.callInt(loaded, mainId) != 40)
			throw "Haxe-owned interface metadata did not dispatch an interface method";
		compiler.update("InterfaceMain.hx",
			"interface Value { function value():Int; } class Box implements Value { public function new() {} public function value():Int return 42; } function main():Int { var value:Value = new Box(); return value.value(); }");
		var changed = compiler.compile("InterfaceMain");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callInt(loaded, mainId) != 42)
			throw "Haxe-owned interface metadata did not dispatch a patched interface method";
		Runtime.dispose(loaded);
	}

	static function testBoundFunctionField():Void {
		var compiler = new Compiler();
		compiler.update("BoundFieldMain.hx",
			"class Box { public var callback:()->Int; public function new() { callback = value; } public function value():Int return 40; } function main():Int { return new Box().callback(); }");
		var initial = compiler.compile("BoundFieldMain"),
			mainId:Int = cast initial.functionIds.get("main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		if (Runtime.callInt(loaded, mainId) != 40)
			throw "Haxe-owned binding metadata did not invoke a function-valued field";
		compiler.update("BoundFieldMain.hx",
			"class Box { public var callback:()->Int; public function new() { callback = value; } public function value():Int return 42; } function main():Int { return new Box().callback(); }");
		var changed = compiler.compile("BoundFieldMain");
		Runtime.patchSet(loaded, new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		if (Runtime.callInt(loaded, mainId) != 42)
			throw "Haxe-owned binding metadata did not invoke a patched function-valued field";
		Runtime.dispose(loaded);
	}

	static function testInheritedInterfaceMethodDispatch():Void {
		var compiler = new Compiler();
		compiler.update("InheritedInterfaceMain.hx",
			"interface Base { function value():Int; } interface Derived extends Base { function extra():Int; } class Box implements Derived { public function new() {} public function value():Int return 40; public function extra():Int return 2; } function main():Int { var value:Base = new Box(); return value.value(); }");
		var initial = compiler.compile("InheritedInterfaceMain"),
			mainId:Int = cast initial.functionIds.get("main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		if (Runtime.callInt(loaded, mainId) != 40)
			throw "Haxe-owned inherited interface metadata did not dispatch a base interface method";
		Runtime.dispose(loaded);
	}

	static function testModuleInitializer():Void {
		var compiler = new Compiler();
		compiler.update("InitializerMain.hx", "class State { public static var value:Int = 40; } function main():Int return State.value;");
		var initial = compiler.compile("InitializerMain"),
			mainId:Int = cast initial.functionIds.get("main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		if (Runtime.callInt(loaded, mainId) != 40)
			throw "Haxe-owned runtime did not execute its module initializer";
		Runtime.dispose(loaded);
	}

	static function testPublicObjectConstant():Void {
		var code = new HlCode();
		code.strings = ["ConstantObject", "value"];
		code.ints = [42];
		code.types = [
			Simple(HlType.I32),
			Simple(HlType.Void),
			Function([], 0),
			Object(0, -1, 1, [{name: 1, type: 0}], [], [])
		];
		code.globals = [3];
		code.constants = [{global: 0, fields: [0]}];
		code.functions = [new HlFunction(2, 0, [3, 0], [GlobalGet(0, 0), FieldGet(1, 0, 0), Return(1)])];
		code.entryPoint = 0;
		var identity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["main" => 0], ["main" => 101]),
			loaded = Runtime.load(HlWriter.encode(code), identity);
		if (Runtime.callInt(loaded, 101) != 42)
			throw "public Haxeon runtime did not materialize an object constant";
		Runtime.dispose(loaded);
	}

	static function testNativeDecodeGuard():Void {
		var compiler = new Compiler();
		compiler.update("DecodeGuardMain.hx", "function main():Int return 40;");
		var initial = compiler.compile("DecodeGuardMain"),
			moduleBytes = HlWriter.encode(initial.module),
			blockedHlb:hl.Abstract<"realtime_module">;
		HlTypeBridge.native_runtime_decode_guard_begin();
		blockedHlb = HlTypeBridge.native_runtime_module_load_bytes(moduleBytes, initial.runtimeIdentity);
		var hlbAttempts = HlTypeBridge.native_runtime_decode_guard_end();
		if (blockedHlb != null || hlbAttempts != 1)
			throw "Haxe-owned decode guard did not reject native HLB decoding";

		compiler.update("DecodeGuardMain.hx", "function main():Int return 42;");
		var changed = compiler.compile("DecodeGuardMain"),
			legacy = HlTypeBridge.native_runtime_module_load_bytes(moduleBytes, initial.runtimeIdentity);
		if (legacy == null)
			throw "legacy native HLB decoding probe could not initialize";
		var patchBytes = changed.patchBytes;
		if (patchBytes == null)
			throw "native HLP decoding probe did not produce a patch";
		var status = haxe.io.Bytes.alloc(4);
		HlTypeBridge.native_runtime_decode_guard_begin();
		var blockedHlp = HlTypeBridge.native_runtime_module_patch_code(legacy, patchBytes, patchBytes.length, cast status.getData()),
			hlpAttempts = HlTypeBridge.native_runtime_decode_guard_end(),
			disposeStatus = HlTypeBridge.native_runtime_module_dispose(legacy);
		if (blockedHlp != null
			|| status.getInt32(0) != RuntimeStatus.BadFormat
			|| hlpAttempts != 1
			|| disposeStatus != RuntimeStatus.Ok)
			throw "Haxe-owned decode guard did not reject native HLP decoding";
		Sys.println("PASS: Haxe-owned runtime rejects native HLB/HLP decoding");
	}

	static function testFailedInitializerCleanup():Void {
		var code = new HlCode();
		code.strings = ["failed initializer"];
		code.types = [Simple(HlType.Bytes), Simple(HlType.Dyn), Simple(HlType.Void), Function([], 2)];
		code.functions = [new HlFunction(3, 0, [0, 1], [LoadString(0, 0), ToDyn(1, 0), Throw(1)])];
		code.entryPoint = 0;
		var identity = HlRuntimeIdentity.encode(haxe.io.Bytes.alloc(16), 1, ["__init" => 0], ["__init" => 101]),
			rejected = false;
		try
			Runtime.load(HlWriter.encode(code), identity);
		catch (error:Dynamic)
			rejected = true;
		if (!rejected || Runtime.pendingRetirementCount != 0)
			throw "failed Haxeon module initialization leaked its registered runtime module";
		Sys.println("PASS: failed Haxeon module initialization cleans up its registered runtime module");
	}
	#end

	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function main():Int { return 40; } function make():() -> Int { return main; } function text():String { return \"haxeon\"; } function consume(value:String):Void {} function makeObject():Box { return new Box(42); } function readObject(box:Box):Int { return box.value; }");
		var initial = compiler.compile("Main"),
			mainId:Int = cast initial.functionIds.get("main"),
			makeId:Int = cast initial.functionIds.get("Main.make"),
			textId:Int = cast initial.functionIds.get("Main.text"),
			consumeId:Int = cast initial.functionIds.get("Main.consume"),
			makeObjectId:Int = cast initial.functionIds.get("Main.makeObject"),
			readObjectId:Int = cast initial.functionIds.get("Main.readObject"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		#if haxeon
		if (Runtime.debugHlbSize(loaded) != 0)
			throw "Haxe-owned runtime load retained an HLB payload for execution";
		#end
		var initialRetirement = Runtime.retirementStatus(loaded),
			initialTypeCount = Runtime.metadataTypeCount(loaded);
		if (Runtime.liveRevision(loaded) != initial.revision
			|| initialTypeCount != initial.module.types.length
			|| Runtime.metadataTypeCapacity(loaded) < initialTypeCount
			|| Runtime.liveAllocationCount(loaded) != initialRetirement.liveManagedAllocations
			|| Runtime.nativeRootCount(loaded) != initialRetirement.ownedNativeRoots
			|| initialRetirement.haxeBorrowers != 0
			|| Runtime.retainedCodeAllocationCount(loaded) != 1
			|| Runtime.patchJitCount(loaded) != 0
			|| Runtime.debugRegionCount(loaded) != 0)
			throw "Haxeon module kernel did not expose consistent runtime diagnostics";
		var moduleRoot:RuntimeGcHandle = Runtime.createGcHandle(loaded, new RuntimeGcHandleValue(7)),
			rootedStatus = Runtime.retirementStatus(loaded);
		if (moduleRoot.isClosed()
			|| cast(moduleRoot.get(), RuntimeGcHandleValue).value != 7
				|| rootedStatus.ownedNativeRoots != initialRetirement.ownedNativeRoots
					+ 1
				|| Runtime.nativeRootCount(loaded) != rootedStatus.ownedNativeRoots)
			throw "runtime module did not account for its explicitly owned GC handle";
		if (Runtime.callString(loaded, textId) != "haxeon")
			throw "Haxeon module kernel did not return a stable string";
		Runtime.callStringArg(loaded, consumeId, "kernel");
		var retainedObject = Runtime.retainObject(loaded, makeObjectId);
		if (Runtime.callIntObject(loaded, readObjectId, retainedObject) != 42)
			throw "Haxeon module kernel did not invoke a retained object";
		retainedObject.release();
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function main():Int { return 42; } function make():() -> Int { return main; } function text():String { return \"haxeon\"; } function consume(value:String):Void {} function makeObject():Box { return new Box(42); } function readObject(box:Box):Int { return box.value; }");
		var changed = compiler.compile("Main"),
			patchSummary = Runtime.inspectPatch(changed.patchBytes),
			patchByte = changed.patchBytes.get(0),
			patchSet = new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions),
			rolledBack = Runtime.stagePatch(loaded, patchSet);
		if (patchSummary.baseRevision != initial.revision
			|| patchSummary.revision != changed.revision
			|| patchSummary.functionCount != changed.changedFunctions.length)
			throw "Haxeon module kernel did not inspect the patch summary";
		changed.patchBytes.set(0, patchByte ^ 0xFF);
		if (patchSet.bytes.get(0) != patchByte)
			throw "PatchSet did not take ownership of its patch bytes";
		changed.patchBytes.set(0, patchByte);
		if (rolledBack.state != Staged || rolledBack.baseRevision != initial.revision)
			throw "host patch transaction did not capture its staging revision";
		if (rolledBack.envelope.baseRevision != initial.revision
			|| rolledBack.envelope.revision != changed.revision
			|| rolledBack.envelope.functionStableIds.length != changed.changedFunctions.length)
			throw "host patch transaction did not retain its publication input";
		rolledBack.rollback();
		if (rolledBack.state != RolledBack)
			throw "host patch transaction did not record rollback";
		try {
			rolledBack.commit();
			throw "rolled-back host patch transaction unexpectedly committed";
		} catch (error:Dynamic) {}
		if (loaded.revision != initial.revision || loaded.committedPatchCount() != 0)
			throw "rolled-back host patch transaction changed published state";

		var committed = Runtime.stagePatch(loaded, patchSet);
		committed.commit();
		if (committed.state != Committed
			|| loaded.revision != changed.revision
			|| Runtime.liveRevision(loaded) != changed.revision
			|| loaded.functions.at(mainId).generation != changed.revision
			|| loaded.committedPatchCount() != 1
			|| loaded.retiredPatchCount() != 0
			|| Runtime.jitGenerationState(loaded, 0) != Runtime.JitGenerationPublished
			|| Runtime.jitGenerationRevision(loaded, 0) != changed.revision
			|| Runtime.callInt(loaded, mainId) != 42
			|| Runtime.retainedCodeAllocationCount(loaded) != 2
			|| Runtime.patchJitCount(loaded) != changed.changedFunctions.length
			|| Runtime.debugRegionCount(loaded) != 1
			|| Runtime.jitLocation(loaded, mainId) == null)
			throw "committed host patch transaction did not publish its generation";
		var retained = Runtime.retainClosure(loaded, makeId);
		if (Runtime.callRetainedClosureInt(retained) != 42)
			throw "Haxeon module kernel did not invoke a retained closure";
		var retainedStatus = Runtime.retirementStatus(loaded);
		if (retainedStatus.haxeBorrowers != 1 || !retainedStatus.hasKnownBorrowers())
			throw "retained runtime values were missing from Haxe retirement diagnostics";
		var retainedSecond = Runtime.retainClosure(loaded, makeId),
			multipleRetainedStatus = Runtime.retirementStatus(loaded);
		if (multipleRetainedStatus.haxeBorrowers != 2)
			throw "Haxe retirement diagnostics did not count multiple retained values";
		retainedSecond.release();
		if (Runtime.retirementStatus(loaded).haxeBorrowers != 1)
			throw "Haxe retirement diagnostics did not update after releasing one retained value";
		try {
			committed.commit();
			throw "committed host patch transaction committed twice";
		} catch (error:Dynamic) {}
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function main():Int { return 43; } function make():() -> Int { return main; } function text():String { return \"haxeon\"; } function consume(value:String):Void {} function makeObject():Box { return new Box(42); } function readObject(box:Box):Int { return box.value; }");
		var appended = compiler.compile("Main"),
			decodedAppended = HlPatchReader.decode(appended.patchBytes),
			stableIdsBySlot:Map<Int, Int> = [],
			changedSlots:Array<Int> = [];
		for (functionPatch in decodedAppended.functions)
			stableIdsBySlot.set(functionPatch.slot, functionPatch.functionIndex);
		for (functionPatch in decodedAppended.functions)
			changedSlots.push(functionPatch.slot);
		appended.module.types.push(Function([], 0));
		var appendedPatch = HlPatchWriter.encode(appended.module, decodedAppended.moduleId, changedSlots, stableIdsBySlot, appended.revision - 1,
			appended.revision, decodedAppended.baseInts, decodedAppended.baseFloats, decodedAppended.baseStrings, initial.module.types.length);
		Runtime.patchSet(loaded, new PatchSet(changed.revision, appended.revision, appendedPatch, appended.changedFunctions));
		if (Runtime.metadataTypeCount(loaded) != initialTypeCount + 1
			|| Runtime.retainedCodeAllocationCount(loaded) != 2
			|| Runtime.patchJitCount(loaded) != changed.changedFunctions.length + appended.changedFunctions.length
			|| loaded.retiredPatchCount() != 1
			|| Runtime.callInt(loaded, mainId) != 43)
			throw "public Haxeon patch publication did not append its Haxe-owned type metadata";
		compiler.update("Main.hx",
			"class Box { public var value:Int; public function new(value:Int):Void { this.value = value; } } function main():Int { return 44; } function make():() -> Int { return main; } function text():String { return \"haxeon\"; } function consume(value:String):Void {} function makeObject():Box { return new Box(42); } function readObject(box:Box):Int { return box.value; }");
		var failed = compiler.compile("Main");
		Runtime.injectPatchFailure(loaded, 1);
		var failureRejected = false;
		try {
			Runtime.patchSet(loaded, new PatchSet(appended.revision, failed.revision, failed.patchBytes, failed.changedFunctions));
		} catch (error:RuntimeError) {
			failureRejected = error.status == RuntimeStatus.Incompatible;
		}
		if (!failureRejected
			|| loaded.revision != appended.revision
			|| Runtime.metadataTypeCount(loaded) != initialTypeCount + 1
			|| Runtime.callInt(loaded, mainId) != 43)
			throw "Haxeon kernel patch failure injection changed published state";
		Runtime.dispose(loaded);
		if (moduleRoot.isClosed() || cast(moduleRoot.get(), RuntimeGcHandleValue).value != 7)
			throw "blocked runtime module retirement closed its owned GC handles too early";
		if (Runtime.jitGenerationState(loaded, 0) != Runtime.JitGenerationRetiring)
			throw "host JIT generation did not enter retiring state while a closure was retained";
		retained.release();
		if (Runtime.pendingRetirementCount != 0)
			throw "deferred module retirement did not finalize when its last retained value was released";
		if (Runtime.retryRetirements() != 0)
			throw "host JIT generation retirement did not drain after releasing its closure";
		if (!moduleRoot.isClosed() || moduleRoot.get() != null)
			throw "runtime module retirement did not close its owned GC handles";
		if (Runtime.pendingRetirementCount != 0)
			throw "Haxeon module kernel did not drain native retirement state";
		#if haxeon
		testEnumPayloadPatch();
		testObjectMethodDispatch();
		testInterfaceMethodDispatch();
		testBoundFunctionField();
		testInheritedInterfaceMethodDispatch();
		testModuleInitializer();
		testFailedInitializerCleanup();
		testPublicObjectConstant();
		testNativeDecodeGuard();
		#end
		Sys.println("PASS: host patch transactions stage, roll back, and commit exactly once");
	}
}
