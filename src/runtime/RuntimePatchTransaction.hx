package runtime;

import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import compiler.hl.patch.HlPatchReader;

/** Lifecycle state for one staged host-runtime HLP transaction. */
enum RuntimePatchTransactionState {
	Staged;
	Committed;
	RolledBack;
}

/**
	Stages one legacy host HLP update under Haxe-owned policy.

	The decoded model is immutable after construction. Compatibility validation,
	native publication, and Haxe state advancement remain one mutex-protected
	commit operation, so a concurrent publisher makes this transaction stale.
 */
class RuntimePatchTransaction {
	public final owner:LoadedModule;
	public final patchSet:PatchSet;
	public final model:HlPatch;
	public final envelope:HlPatchEnvelope;
	public final baseRevision:Int;
	public var state(default, null):RuntimePatchTransactionState = Staged;

	public function new(owner:LoadedModule, patchSet:PatchSet) {
		if (owner == null || patchSet == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime patch transactions require an owner and patch set");
		this.owner = owner;
		this.patchSet = patchSet;
		try {
			model = HlPatchReader.decode(patchSet.bytes);
		} catch (error:RuntimeError) {
			throw error;
		} catch (error:Dynamic) {
			throw new RuntimeError(RuntimeStatus.BadFormat, 'Haxeon rejected the HLP patch: ${Std.string(error)}');
		}
		envelope = model.envelope();
		baseRevision = owner.revision;
		if (envelope.moduleId.compare(owner.identity.moduleId) != 0)
			throw new RuntimeError(RuntimeStatus.Incompatible, "Haxeon rejected an HLP patch for another module");
		if (patchSet.baseRevision != envelope.baseRevision || patchSet.revision != envelope.revision)
			throw new RuntimeError(RuntimeStatus.BadArgument, "PatchSet revision metadata does not match the HLP envelope");
		if (!sameFunctionIds(patchSet.changedFunctions, envelope.functionStableIds))
			throw new RuntimeError(RuntimeStatus.BadArgument, "PatchSet function metadata does not match the HLP envelope");
	}

	/** Commit this patch only if the owner is still at its staged revision. */
	public function commit():Void {
		requireStaged();
		Runtime.commitPatch(this);
		state = Committed;
	}

	/** Discard an uncommitted patch transaction. */
	public function rollback():Void {
		if (state == Staged)
			state = RolledBack;
	}

	function requireStaged():Void {
		switch state {
			case Staged:
			case Committed:
				throw "Runtime patch transaction has already committed";
			case RolledBack:
				throw "Runtime patch transaction has already rolled back";
		}
	}

	static function sameFunctionIds(left:Array<Int>, right:Array<Int>):Bool {
		if (left == null || right == null || left.length != right.length)
			return false;
		var seen:Map<Int, Bool> = [];
		for (stableId in left) {
			if (seen.exists(stableId) || right.indexOf(stableId) < 0)
				return false;
			seen.set(stableId, true);
		}
		return true;
	}
}
