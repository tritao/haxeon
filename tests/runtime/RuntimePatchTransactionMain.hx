import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimePatchTransaction.RuntimePatchTransactionState;

class RuntimePatchTransactionMain {
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
		var initialRetirement = Runtime.retirementStatus(loaded),
			initialTypeCount = Runtime.metadataTypeCount(loaded);
		if (Runtime.liveRevision(loaded) != initial.revision
			|| initialTypeCount != initial.module.types.length
			|| Runtime.metadataTypeCapacity(loaded) < initialTypeCount
			|| Runtime.liveAllocationCount(loaded) != initialRetirement.liveManagedAllocations
			|| Runtime.nativeRootCount(loaded) != initialRetirement.ownedNativeRoots)
			throw "Haxeon module kernel did not expose consistent runtime diagnostics";
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
			patchByte = changed.patchBytes.get(0),
			patchSet = new PatchSet(initial.revision, changed.revision, changed.patchBytes, changed.changedFunctions),
			rolledBack = Runtime.stagePatch(loaded, patchSet);
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
			|| Runtime.jitGenerationState(loaded, 0) != Runtime.JitGenerationPublished
			|| Runtime.jitGenerationRevision(loaded, 0) != changed.revision
			|| Runtime.callInt(loaded, mainId) != 42)
			throw "committed host patch transaction did not publish its generation";
		var retained = Runtime.retainClosure(loaded, makeId);
		if (Runtime.callRetainedClosureInt(retained) != 42)
			throw "Haxeon module kernel did not invoke a retained closure";
		try {
			committed.commit();
			throw "committed host patch transaction committed twice";
		} catch (error:Dynamic) {}
		Runtime.dispose(loaded);
		if (Runtime.jitGenerationState(loaded, 0) != Runtime.JitGenerationRetiring)
			throw "host JIT generation did not enter retiring state while a closure was retained";
		retained.release();
		if (Runtime.retryRetirements() != 0)
			throw "host JIT generation retirement did not drain after releasing its closure";
		if (Runtime.pendingRetirementCount != 0)
			throw "Haxeon module kernel did not drain native retirement state";
		Sys.println("PASS: host patch transactions stage, roll back, and commit exactly once");
	}
}
