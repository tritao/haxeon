package runtime;

#if haxeon
import compiler.hl.HlNativeMetadataBuilder;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlMetadataTypeAppend;
import runtime.hashlink.HlRuntimeJitBackend;

/**
	Haxe-owned HashLink patch publication policy for the host runtime facade.

	This class constructs the complete metadata transaction before handing it to
	the narrow native JIT publication seam. The native backend only receives
	stable arena-owned records and either publishes or rejects them.
 */
class HaxeRuntimePatchPublisher {
	public static function publish(backend:HlRuntimeJitBackend, module:RuntimeModuleHandle, transaction:RuntimePatchTransaction):RuntimeJitPublication {
		if (backend == null || transaction == null || transaction.owner.metadata == null)
			return new RuntimeJitPublication(RuntimeStatus.BadArgument, null);
		var metadata:HlMetadataGeneration = transaction.owner.metadata,
			typeAppend:HlMetadataTypeAppend = null;
		try {
			typeAppend = HlNativeMetadataBuilder.preparePatchTypes(transaction.owner.model, metadata, transaction.model);
			var patchPools = HlNativeMetadataBuilder.preparePatchPools(transaction.owner.model, metadata, transaction.model);
			var patchFunctions = HlNativeMetadataBuilder.preparePatchFunctions(metadata, transaction.model, transaction.owner.identity);
			var patchDebug = HlNativeMetadataBuilder.preparePatchDebug(metadata, transaction.model);
			var patchResolution = HlNativeMetadataBuilder.preparePatchResolution(metadata, transaction.model, transaction.owner.identity);
			var patchInput = HlNativeMetadataBuilder.preparePatchInput(metadata, transaction.model, patchDebug, patchResolution);
			var publication = backend.patchCodeWithHaxeMetadata(cast module, patchInput, transaction.model.types.length, patchFunctions, patchPools,
				patchDebug);
			if (publication.status != RuntimeStatus.Ok) {
				typeAppend.rollback();
				if (publication.code != null)
					backend.releaseCode(publication.code);
				return new RuntimeJitPublication(cast publication.status, null);
			}
			try {
				typeAppend.commit();
			} catch (error:Dynamic) {
				if (publication.code != null)
					backend.releaseCode(publication.code);
				typeAppend.rollback();
				throw error;
			}
			return new RuntimeJitPublication(cast publication.status, cast publication.code);
		} catch (error:Dynamic) {
			if (typeAppend != null)
				typeAppend.rollback();
			throw error;
		}
	}
}
#end
