package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;
import runtime.memory.Mutex;
import runtime.memory.GcHandle;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlPatchDebug;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlPatchInput;
import runtime.hashlink.HashLinkModuleBindings.NativeModuleHlPatchPools;

/** Owns one runtime wrapper initialized from Haxe-built HashLink metadata. */
class HlRuntimeModule {
	public static var defaultKernel(default, null):HlRuntimeModuleKernel = new NativeHlRuntimeModuleKernel();
	public static var defaultJitBackend(default, null):HlRuntimeJitBackend = new NativeHlRuntimeJitBackend();

	public final metadata:HlMetadataGeneration;
	final lease:HlMetadataLease;
	final kernel:HlRuntimeModuleKernel;
	final jitBackend:HlRuntimeJitBackend;
	final moduleMutex:Mutex = Mutex.create();
	final dispatch:HlRuntimeDispatchTable;
	final gcHandles:Array<GcHandle<Dynamic>> = [];
	var module:Null<hl.Abstract<"realtime_module">>;
	var constantsInitialized:Bool = false;

	public function new(metadata:HlMetadataGeneration, bytes:Bytes, moduleId:Bytes, revision:Int, stableIds:Array<Int>, slots:Array<Int>, initializerSlot:Int,
		?jitBackend:HlRuntimeJitBackend, ?kernel:HlRuntimeModuleKernel) {
		if (metadata == null || bytes == null || moduleId == null || moduleId.length != 16 || stableIds == null || slots == null
			|| stableIds.length != slots.length || revision < 0 || initializerSlot < -1
			|| kernel == null && defaultKernel == null || jitBackend == null && defaultJitBackend == null)
			throw "HashLink runtime module requires metadata, HLB bytes, and a decoded HLI manifest";
		this.metadata = metadata;
		this.kernel = kernel == null ? defaultKernel : kernel;
		this.jitBackend = jitBackend == null ? defaultJitBackend : jitBackend;
		lease = metadata.acquire();
		module = null;
		try {
			var publication = metadata.snapshot();
			dispatch = new HlRuntimeDispatchTable(metadata.arena, stableIds, slots, initializerSlot, metadata.functionCount());
			module = this.kernel.loadCodeManifest(publication.nativeCode, bytes, moduleId, revision, dispatch);
			if (module == null)
				throw "HashLink external runtime module initialization failed";
			HlTypeLayout.publishObjectPrototypes(publication.types, publication.typeCount, this.kernel);
		} catch (error:Dynamic) {
			if (module != null) {
				this.kernel.dispose(cast module);
				module = null;
			}
			lease.release();
			throw error;
		}
	}

	/** Materialize constants after the outer Haxe lifecycle owner is registered. */
	@:allow(compiler.hl.HlLoadedRuntimeModule)
	function initializeConstants():Void {
		withLock(function() {
			if (module == null)
				throw "HashLink external runtime module is no longer loaded";
			if (constantsInitialized)
				throw "HashLink external runtime module constants were already initialized";
			metadata.constantDescriptors.initialize(function(index)
				return kernel.initializeConstant(cast module, index));
			constantsInitialized = true;
		});
	}

	/** Whether the native runtime wrapper remains initialized. */
	public function isLoaded():Bool
		return withLock(function() return module != null);

	/** Create a managed root whose lifetime is bounded by this runtime module. */
	public function createGcHandle<T>(value:T):GcHandle<T>
		return withModule(function(handle) {
			var result = GcHandle.createOwned(value, cast handle);
			gcHandles.push(cast result);
			return result;
		});

	/** Invoke a stable zero-argument i32 function. */
	public function callI32(stableId:Int):Int
		return withModule(function(handle) return kernel.callI32Slot(handle, slotOf(stableId)));

	/** Invoke a stable zero-argument void function. */
	public function callVoid(stableId:Int):Void
		withModule(function(handle) kernel.callVoidSlot(handle, slotOf(stableId)));

	function slotOf(stableId:Int):Int {
		var slot = dispatch.slotOf(stableId);
		if (slot < 0)
			throw 'HashLink external runtime module has no function identity $stableId';
		return slot;
	}

	/** Apply an HLP transaction; policy validation belongs to the owning loader. */
	public function patch(bytes:Bytes):Int
		return withModule(function(handle) {
			if (bytes == null)
				throw "HashLink external runtime patch requires patch bytes";
			return jitBackend.patch(handle, bytes);
		});

	/** Inject one native patch-staging failure for external rollback tests. */
	public function setPatchFailureStage(stage:Int):Void
		withModule(function(handle) kernel.setPatchFailureStage(handle, stage));

	/** Apply a patch while retaining the published native code allocation. */
	public function patchCode(bytes:Bytes):HlRuntimePatchPublication
		return withModule(function(handle) {
			if (bytes == null)
				throw "HashLink external runtime patch requires patch bytes";
			return patchCodeInternal(handle, bytes, -1);
		});

	/** Apply a patch while using Haxe-owned compatible appended type records. */
	public function patchCodeWithHaxeTypes(bytes:Bytes, typeCount:Int):HlRuntimePatchPublication
		return withModule(function(handle) {
			if (bytes == null || typeCount < 0)
				throw "HashLink external runtime patch requires patch bytes and a non-negative type count";
			return patchCodeInternal(handle, bytes, typeCount);
		});

	/** Apply a patch while using Haxe-owned type and function metadata. */
	public function patchCodeWithHaxeMetadata(input:RawPtr<NativeModuleHlPatchInput>, typeCount:Int, functions:HlRuntimePatchFunctions,
		pools:RawPtr<NativeModuleHlPatchPools>, debug:RawPtr<NativeModuleHlPatchDebug>):HlRuntimePatchPublication
		return withModule(function(handle) {
			if (input.isNull() || typeCount < 0 || functions == null || pools.isNull() || debug.isNull())
				throw "HashLink external runtime patch requires decoded patch input, type count, function metadata, scalar pools, and debug metadata";
			return jitBackend.patchCodeWithHaxeMetadata(handle, input, typeCount, functions, pools, debug);
		});

	function patchCodeInternal(handle:HlRuntimeModuleHandle, bytes:Bytes, typeCount:Int):HlRuntimePatchPublication {
		return typeCount < 0 ? jitBackend.patchCode(handle, bytes) : jitBackend.patchCodeWithHaxeTypes(handle, bytes, typeCount);
	}

	/** Release one externally retained patch-code allocation. */
	public function releaseCode(code:Null<hl.Abstract<"realtime_jit_code">>):Bool
		return withLock(function() return jitBackend.releaseCode(cast code));

	/** Read the immutable revision carried by one retained patch-code allocation. */
	public function codeRevision(code:Null<hl.Abstract<"realtime_jit_code">>):Int
		return withLock(function() return jitBackend.codeRevision(cast code));

	/** Retire the wrapper, preserving the metadata lease if native borrowers block it. */
	public function unload():Bool {
		return withLock(function() {
			var current = module;
			if (current == null)
				return true;
			if (!kernel.unload(cast current))
				return false;
			closeGcHandles();
			module = null;
			lease.release();
			return true;
		});
	}

	function closeGcHandles():Void {
		for (handle in gcHandles)
			handle.close();
		gcHandles.resize(0);
	}

	function withModule<T>(operation:HlRuntimeModuleHandle->T):T {
		return withLock(function() {
			if (module == null)
				throw "HashLink external runtime module is no longer loaded";
			return operation(cast module);
		});
	}

	function withLock<T>(operation:Void->T):T {
		moduleMutex.acquire();
		try {
			var result = operation();
			moduleMutex.release();
			return result;
		} catch (error:Dynamic) {
			moduleMutex.release();
			throw error;
		}
	}
}
