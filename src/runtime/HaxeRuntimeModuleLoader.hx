package runtime;

#if haxeon
import haxe.io.Bytes;
import compiler.hl.HlModule;
import compiler.hl.HlNativeMetadataBuilder;
import compiler.hl.HlRuntimeCallPolicy;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlRuntimeDispatchTable;
import runtime.hashlink.HlRuntimeJitBackend.HlRuntimeModuleHandle;
import runtime.hashlink.HlRuntimeModuleKernel;
import runtime.hashlink.HlTypeLayout;

/**
	Haxe-owned loader for a HashLink runtime module and its native metadata.

	The loader constructs the complete metadata graph and only then hands the
	stable native view and decoded identity tables to the bootstrap kernel.
 */
class HaxeRuntimeModuleLoader {
	final kernel:HlRuntimeModuleKernel;

	public function new(kernel:HlRuntimeModuleKernel) {
		if (kernel == null)
			throw "Haxeon runtime module loading requires a native kernel";
		this.kernel = kernel;
	}

	public function load(bytes:Bytes, model:HlModule, identity:HlRuntimeManifest):LoadedModule {
		if (bytes == null || model == null || identity == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Haxeon runtime module loading requires decoded module state");
		var metadata:HlMetadataGeneration;
		try {
			metadata = HlNativeMetadataBuilder.buildModule(model);
		} catch (error:Dynamic) {
			throw new RuntimeError(RuntimeStatus.BadFormat, 'Haxeon rejected the native metadata: ${Std.string(error)}');
		}
		var module:Null<HlRuntimeModuleHandle> = null;
		var loaded:Null<LoadedModule> = null;
		try {
			var publication = metadata.snapshot(),
				dispatch = new HlRuntimeDispatchTable(metadata.arena, [for (entry in identity.entries) entry.stableId],
					[for (entry in identity.entries) entry.functionIndex], identity.initializerSlot);
			module = kernel.loadCodeManifest(publication.nativeCode, bytes, identity.moduleId, identity.revision, dispatch);
			if (module == null)
				throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the Haxe-owned module metadata");
			// Register the native handle with the Haxe lifecycle owner before any
			// GC-sensitive initialization can fail. A blocked cleanup must retain
			// both the handle and its metadata arena for a later retry.
			loaded = new LoadedModule(module, model, identity, metadata, dispatch);
			HlTypeLayout.publishObjectPrototypes(publication.types, publication.typeCount, kernel);
			metadata.constantDescriptors.initialize(function(index) return kernel.initializeConstant(cast module, index));
			initializeModule(module, model, identity, dispatch);
			return loaded;
		} catch (error:Dynamic) {
			if (loaded != null)
				Runtime.dispose(loaded);
			else
				metadata.dispose();
			throw error;
		}
	}

	function initializeModule(module:HlRuntimeModuleHandle, model:HlModule, identity:HlRuntimeManifest, dispatch:HlRuntimeDispatchTable):Void {
		if (identity.initializerSlot < 0)
			return;
		for (entry in identity.entries)
			if (entry.functionIndex == identity.initializerSlot) {
				if (!HlRuntimeCallPolicy.validFunction(model, identity, entry.stableId, 1))
					throw new RuntimeError(RuntimeStatus.BadFunction, "Haxeon rejected an invalid module initializer");
				var slot = dispatch.slotOf(entry.stableId);
				if (slot < 0)
					throw new RuntimeError(RuntimeStatus.BadFormat, "Haxeon could not resolve the module initializer slot");
				kernel.callVoidSlot(module, slot);
				return;
			}
		throw new RuntimeError(RuntimeStatus.BadFormat, "Haxeon could not resolve the module initializer");
	}
}
#end
