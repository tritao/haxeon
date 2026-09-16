import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimePatchTransaction.RuntimePatchTransactionState;

class RuntimePatchTransactionMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", "function main():Int { return 40; }");
		var initial = compiler.compile("Main"),
			mainId = initial.functionIds.get("main"),
			loaded = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity);
		compiler.update("Main.hx", "function main():Int { return 42; }");
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
			|| loaded.functions.at(mainId).generation != changed.revision
			|| loaded.committedPatchCount() != 1
			|| Runtime.jitGenerationState(loaded, 0) != Runtime.JitGenerationPublished
			|| Runtime.callInt(loaded, mainId) != 42)
			throw "committed host patch transaction did not publish its generation";
		try {
			committed.commit();
			throw "committed host patch transaction committed twice";
		} catch (error:Dynamic) {}
		Runtime.dispose(loaded);
		Sys.println("PASS: host patch transactions stage, roll back, and commit exactly once");
	}
}
