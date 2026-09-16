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
		try {
			var publication = metadata.snapshot(),
				dispatch = new HlRuntimeDispatchTable(metadata.arena, [for (entry in identity.entries) entry.stableId],
					[for (entry in identity.entries) entry.functionIndex], identity.initializerSlot);
			module = kernel.loadCodeManifest(publication.nativeCode, bytes, identity.moduleId, identity.revision, dispatch);
			if (module == null)
				throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the Haxe-owned module metadata");
			if (!kernel.publishObjectPrototypes(module))
				throw new RuntimeError(RuntimeStatus.JitFailed, "HashLink rejected Haxe-owned object prototypes");
			metadata.constantDescriptors.initialize(function(index) return kernel.initializeConstant(cast module, index));
			initializeModule(module, model, identity);
			return new LoadedModule(module, model, identity, metadata);
		} catch (error:Dynamic) {
			if (module != null)
				kernel.dispose(cast module);
			metadata.dispose();
			throw error;
		}
	}

	function initializeModule(module:HlRuntimeModuleHandle, model:HlModule, identity:HlRuntimeManifest):Void {
		if (identity.initializerSlot < 0)
			return;
		for (entry in identity.entries)
			if (entry.functionIndex == identity.initializerSlot) {
				if (!HlRuntimeCallPolicy.validFunction(model, identity, entry.stableId, 1))
					throw new RuntimeError(RuntimeStatus.BadFunction, "Haxeon rejected an invalid module initializer");
				kernel.callVoid(module, entry.stableId);
				return;
			}
		throw new RuntimeError(RuntimeStatus.BadFormat, "Haxeon could not resolve the module initializer");
	}
}
#end
