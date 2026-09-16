package runtime;

#if haxeon
import haxe.io.Bytes;
import compiler.hl.HlModule;
import compiler.hl.HlNativeMetadataBuilder;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlRuntimeModuleKernel;
import runtime.memory.RawPtr;

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
		var publication = metadata.snapshot(),
			count = identity.entries.length,
			stableIdStorage:RawPtr<Int32> = count == 0 ? RawPtr.nullPtr() : metadata.arena.allocInt32Array(count),
			slotStorage:RawPtr<Int32> = count == 0 ? RawPtr.nullPtr() : metadata.arena.allocInt32Array(count);
		for (index in 0...count) {
			var entry = identity.entries[index];
			stableIdStorage.offset(index).store(cast entry.stableId);
			slotStorage.offset(index).store(cast entry.functionIndex);
		}
		var module = kernel.loadCodeManifest(publication.nativeCode, bytes, identity.moduleId, identity.revision, stableIdStorage, slotStorage, count,
			identity.initializerSlot);
		if (module == null) {
			metadata.dispose();
			throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the Haxe-owned module metadata");
		}
		try {
			return new LoadedModule(module, model, identity, metadata);
		} catch (error:Dynamic) {
			kernel.dispose(cast module);
			metadata.dispose();
			throw error;
		}
	}
}
#end
