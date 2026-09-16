package runtime;

#if haxeon
import compiler.hl.HlPatchPolicy;

/**
	Haxe-owned hot-reload policy for the public runtime facade.

	The coordinator validates and snapshots a patch while the module is locked,
	then delegates executable publication to the backend seam. Native code never
	decides revision compatibility or function-generation ownership.
 */
class HaxeRuntimePatchCoordinator {
	final jitBackend:RuntimeJitBackend;

	public function new(jitBackend:RuntimeJitBackend) {
		if (jitBackend == null)
			throw "Haxeon runtime patch coordination requires a JIT backend";
		this.jitBackend = jitBackend;
	}

	public function commit(transaction:RuntimePatchTransaction):RuntimeStatus {
		if (transaction == null)
			return RuntimeStatus.BadArgument;
		var module = transaction.owner,
			envelope = transaction.envelope,
			decoded = transaction.model;
		return module.access(function(handle) {
			if (envelope.baseRevision != module.revision || transaction.baseRevision != module.revision)
				throw new RuntimeError(RuntimeStatus.StalePatch,
					'Patch base revision ${envelope.baseRevision} does not match live revision ${module.revision}');
			try {
				HlPatchPolicy.validate(module.model, module.identity, module.revision, envelope, decoded);
			} catch (error:RuntimeError) {
				throw error;
			} catch (error:Dynamic) {
				throw new RuntimeError(RuntimeStatus.Incompatible, 'Haxeon rejected the HLP patch: ${Std.string(error)}');
			}
			var nextFunctions:RuntimeFunctionVersionTable;
			try {
				nextFunctions = module.functions.advance(envelope.functionStableIds, envelope.revision);
			} catch (error:RuntimeError) {
				throw error;
			} catch (error:Dynamic) {
				throw new RuntimeError(RuntimeStatus.Incompatible, 'Haxeon rejected the HLP function generation: ${Std.string(error)}');
			}
			var generation:RuntimePatchGeneration;
			try {
				generation = new RuntimePatchGeneration(decoded, envelope, nextFunctions);
			} catch (error:RuntimeError) {
				throw error;
			} catch (error:Dynamic) {
				throw new RuntimeError(RuntimeStatus.Incompatible, 'Haxeon rejected the HLP generation snapshot: ${Std.string(error)}');
			}
			var publication = jitBackend.applyPatch(handle, transaction);
			if (publication.status == RuntimeStatus.Ok) {
				module.commitPatch(generation);
				module.recordJitPublication(jitBackend, generation.revision, publication.code);
			}
			return publication.status;
		});
	}
}
#end
