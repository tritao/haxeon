package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.memory.GcHandle;
import runtime.memory.Mutex;

/** Owns one initialized native HashLink module and its metadata lease. */
class HlNativeModule {
	static final moduleMutex:Mutex = Mutex.create();
	public static final defaultKernel:HlMetadataModuleKernel = new NativeHlMetadataModuleKernel();
	/** HashLink flag that installs stable entries for native generation patches. */
	public static inline final PatchableFlag:Int = 8;
	/** HashLink flag that preserves Haxeon-derived enum and virtual metadata. */
	public static inline final HaxeMetadataFlag:Int = 16;

	public final metadata:HlMetadataGeneration;
	public final publication:HlMetadataPublication;
	final lease:HlMetadataLease;
	final kernel:HlMetadataModuleKernel;
	final gcHandles:Array<GcHandle<Dynamic>> = [];
	var module:RawPtr<UInt8>;
	var constantsInitialized:Bool = false;

	public function new(metadata:HlMetadataGeneration, ?flags:Int = 0, ?kernel:HlMetadataModuleKernel) {
		if (metadata == null)
			throw "HashLink native module requires metadata";
		this.metadata = metadata;
		this.kernel = kernel == null ? defaultKernel : kernel;
		lease = metadata.acquire();
		publication = lease.publication;
		module = RawPtr.nullPtr();
		try {
			module = this.kernel.allocate(publication.nativeCode);
			if (module.isNull())
				throw "HashLink native module allocation failed";
			if (!this.kernel.initialize(module, flags | HaxeMetadataFlag)) {
				this.kernel.freeShutdown(module);
				module = RawPtr.nullPtr();
				throw "HashLink native module initialization failed";
			}
			if (!this.kernel.publishObjectPrototypes(module)) {
				this.kernel.freeShutdown(module);
				module = RawPtr.nullPtr();
				throw "HashLink native object-prototype publication failed";
			}
			initializeConstants();
		} catch (error:Dynamic) {
			if (!module.isNull())
				this.kernel.freeShutdown(module);
			lease.release();
			throw error;
		}
	}

	function initializeConstants():Void {
		if (constantsInitialized)
			throw "HashLink native module constants were already initialized";
		metadata.constantDescriptors.initialize(function(index)
			return kernel.initializeConstant(module, index));
		constantsInitialized = true;
	}

	/** Whether the native module remains initialized and owned by this wrapper. */
	public inline function isLoaded():Bool
		return withLock(function() return !module.isNull());

	/** Native handle for kernel operations that are not policy-owned yet. */
	public function pointer():RawPtr<UInt8> {
		return withLock(function() {
			if (module.isNull())
				throw "HashLink native module is no longer loaded";
			return module;
		});
	}

	/** Invoke a zero-argument Haxe-owned function through HashLink's JIT. */
	public function callI32(functionIndex:Int):Int {
		return withLock(function() {
			if (module.isNull())
				throw "HashLink native module is no longer loaded";
			return kernel.callI32(module, functionIndex);
		});
	}

	/** Create a managed root whose lifetime is bounded by this native module. */
	public function createGcHandle<T>(value:T):GcHandle<T> {
		return withLock(function() {
			if (module.isNull())
				throw "HashLink native module is no longer loaded";
			var result:GcHandle<T> = GcHandle.createOwnedRaw(value, module);
			gcHandles.push(cast result);
			return result;
		});
	}

	/** Redirect this patchable module to the compatible function generation. */
	public function patchGeneration(generation:HlNativeModule):Bool {
		return withLock(function() {
			if (module.isNull() || generation == null || !generation.isLoaded())
				throw "HashLink native module patch requires two loaded modules";
			if (generation == this)
				throw "HashLink native module cannot patch itself";
			return kernel.patchGeneration(module, generation.module);
		});
	}

	/** Redirect only the selected compatible dispatch slots to a generation. */
	public function patchSlots(generation:HlNativeModule, slots:Array<Int>):Bool {
		return withLock(function() {
			if (module.isNull() || generation == null || !generation.isLoaded())
				throw "HashLink native module patch requires two loaded modules";
			if (generation == this)
				throw "HashLink native module cannot patch itself";
			if (slots == null || slots.length == 0)
				throw "HashLink native module patch requires at least one slot";
			var indices = generation.metadata.arena.allocInt32Array(slots.length), seen:Map<Int, Bool> = [];
			for (index in 0...slots.length) {
				var slot = slots[index];
				if (slot < 0 || seen.exists(slot))
					throw "HashLink native module patch slots must be unique and non-negative";
				seen.set(slot, true);
				indices.offset(index).store(cast slot);
			}
			return kernel.patchSlots(module, generation.module, indices, slots.length);
		});
	}

	/** Try to retire the module; a failed retirement keeps its lease and handle alive. */
	public function unload():Bool {
		return withLock(function() {
			if (module.isNull())
				return true;
			if (!kernel.unload(module))
				return false;
			closeGcHandles();
			module = RawPtr.nullPtr();
			lease.release();
			return true;
		});
	}

	function closeGcHandles():Void {
		for (handle in gcHandles)
			handle.close();
		gcHandles.resize(0);
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

	/** Require native retirement and report a live-allocation failure to the caller. */
	public function close():Void {
		if (!unload())
			throw "HashLink native module could not be unloaded";
	}
}
