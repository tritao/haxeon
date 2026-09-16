package runtime;

import compiler.hl.HlModule;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
import runtime.RuntimeModuleHandle.RuntimeGcHandle;
#if haxeon
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlRuntimeDispatchTable;
#end
import sys.thread.Mutex;

/** Exclusive owner of one native runtime module handle. */
class LoadedModule {
	/** Validated Haxe-owned module model retained beside the native handle. */
	public final model:HlModule;

	/** Validated Haxe-owned runtime identity retained beside the native handle. */
	public final identity:HlRuntimeManifest;

	/** Haxe-owned revision, function-version, and generation state. */
	final patchState:RuntimePatchState;

	/** Haxe-owned revision corresponding to the last successful native publication. */
	public var revision(get, never):Int;

	/** Stable function identities and their current Haxe-side generations. */
	public var functions(get, never):RuntimeFunctionVersionTable;

	/** Haxe-owned JIT allocations retained by this module's patch generations. */
	final jitGenerations:Array<RuntimeJitGeneration> = [];

	/** Explicit managed roots whose owner is this native runtime module. */
	final gcHandles:Array<RuntimeGcHandle> = [];

	#if haxeon
	/** Haxe-owned native metadata retained for the lifetime of this module. */
	public final metadata:HlMetadataGeneration;

	/** Immutable Haxe-resolved dispatch slots for the native module. */
	final dispatch:HlRuntimeDispatchTable;
	#end

	final mutex = new Mutex();
	var handle:Null<RuntimeModuleHandle>;
	var closeRequested = false;
	var borrowers = 0;
	var deferredDispose:Null<RuntimeModuleHandle->Void>;
	@:allow(runtime.Runtime)
	#if haxeon
	function new(handle:RuntimeModuleHandle, model:HlModule, identity:HlRuntimeManifest, metadata:HlMetadataGeneration, dispatch:HlRuntimeDispatchTable) {
		if (metadata == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Haxeon runtime modules require an owned metadata generation");
		this.metadata = metadata;
		this.dispatch = dispatch;
	#else
	function new(handle:RuntimeModuleHandle, model:HlModule, identity:HlRuntimeManifest) {
	#end
		this.handle = handle;
		this.model = model;
		this.identity = identity;
		patchState = new RuntimePatchState(identity.revision, functionVersions(model, identity));
	}

	function get_revision():Int
		return patchState.revision;

	function get_functions():RuntimeFunctionVersionTable
		return patchState.functions;

	#if haxeon
	/** Resolve a validated stable identity to its immutable native dispatch slot. */
	@:allow(runtime.Runtime)
	function dispatchSlot(stableId:Int):Int {
		var slot = dispatch.slotOf(stableId);
		if (slot < 0)
			throw new RuntimeError(RuntimeStatus.BadFunction, 'Runtime module has no function identity $stableId');
		return slot;
	}
	#end

	/** Create a managed root that is closed automatically when this module retires. */
	@:allow(runtime.Runtime)
	function createGcHandle<T>(value:T):RuntimeGcHandle {
		return access(function(current) {
			var result = RuntimeGcHandle.createOwned(value, cast current);
			gcHandles.push(cast result);
			return result;
		});
	}

	/** Number of successfully published Haxe-owned patch generations. */
	public inline function committedPatchCount():Int
		return patchState.committedPatchCount();

	/** Number of committed patch generations whose functions are all superseded. */
	public inline function retiredPatchCount():Int
		return patchState.retiredPatchCount();

	/** Return the lifecycle state for one retained JIT generation. */
	@:allow(runtime.Runtime)
	function jitGenerationState(index:Int):Int {
		if (index < 0 || index >= jitGenerations.length)
			throw new RuntimeError(RuntimeStatus.BadArgument, 'Runtime JIT generation index $index is unavailable');
		return jitGenerations[index].state;
	}

	/** Return the native revision for one retained JIT generation. */
	@:allow(runtime.Runtime)
	function jitGenerationRevision(index:Int):Int {
		if (index < 0 || index >= jitGenerations.length)
			throw new RuntimeError(RuntimeStatus.BadArgument, 'Runtime JIT generation index $index is unavailable');
		return jitGenerations[index].codeRevision();
	}

	/** Retain one successfully published JIT allocation with this module. */
	@:allow(runtime.Runtime, runtime.HaxeRuntimePatchCoordinator)
	function recordJitPublication(backend:RuntimeJitBackend, revision:Int, code:RuntimeJitCodeHandle):Void
		jitGenerations.push(new RuntimeJitGeneration(backend, revision, code, Runtime.JitGenerationPublished));

	/** Mark every retained generation as awaiting module retirement. */
	@:allow(runtime.Runtime)
	function beginJitRetirement():Void {
		for (generation in jitGenerations)
			generation.markRetiring(Runtime.JitGenerationRetiring);
	}

	/** Release every JIT allocation after native module retirement succeeds. */
	@:allow(runtime.Runtime)
	function finishJitRetirement():Void {
		for (generation in jitGenerations)
			if (!generation.release())
				throw new RuntimeError(RuntimeStatus.RetirementBlocked, "Runtime JIT generation release failed");
		jitGenerations.resize(0);
	}

	/** Advance Haxe-owned state after the native patch has been published. */
	@:allow(runtime.Runtime, runtime.HaxeRuntimePatchCoordinator)
	function commitPatch(generation:RuntimePatchGeneration):Void {
		if (generation == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime patch state requires a prepared generation");
		var patchModel = generation.patch;
		for (value in patchModel.ints)
			model.code.ints.push(value);
		for (value in patchModel.floats)
			model.code.floats.push(value);
		for (value in patchModel.strings)
			model.code.strings.push(value);
		for (type in patchModel.types)
			model.code.types.push(type);
		patchState.publish(generation);
	}

	static function functionVersions(model:HlModule, identity:HlRuntimeManifest):RuntimeFunctionVersionTable {
		var entries:Array<{stableId:Int, slot:Int, typeIndex:Int}> = [];
		for (entry in identity.entries) {
			var fn = model.functionAt(entry.functionIndex);
			if (fn == null)
				throw new RuntimeError(RuntimeStatus.BadFormat, 'HLI identity references missing bytecode function ${entry.functionIndex}');
			entries.push({
				stableId: entry.stableId,
				slot: entry.functionIndex,
				typeIndex: fn.type
			});
		}
		return new RuntimeFunctionVersionTable(entries, identity.revision);
	}

	@:allow(runtime.Runtime, runtime.HaxeRuntimePatchCoordinator)
	function access<T>(operation:RuntimeModuleHandle->T):T {
		mutex.acquire();
		var current = handle;
		if (current == null || closeRequested) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime module has been disposed");
		}
		try {
			var result = operation(current);
			mutex.release();
			return result;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}

	@:allow(runtime.Runtime)
	function accessRetained(operation:RuntimeModuleHandle->Dynamic):Dynamic {
		mutex.acquire();
		var current = handle;
		if (current == null || closeRequested) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime module has been disposed");
		}
		try {
			var result = operation(current);
			borrowers++;
			mutex.release();
			return result;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}

	@:allow(runtime.RetainedValue)
	function accessBorrowed<T>(operation:RuntimeModuleHandle->T):T {
		mutex.acquire();
		var current = handle;
		if (current == null || borrowers <= 0) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Retained runtime module is unavailable");
		}
		try {
			var result = operation(current);
			mutex.release();
			return result;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}

	@:allow(runtime.RetainedValue)
	function release():Void {
		mutex.acquire();
		if (borrowers <= 0) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime module borrow count is invalid");
		}
		borrowers--;
		if (borrowers == 0 && closeRequested) {
			var current = handle, dispose = deferredDispose;
			if (current != null && dispose != null) {
				try {
					dispose(current);
					handle = null;
					deferredDispose = null;
					closeGcHandles();
				} catch (error:RuntimeError) {
					if (error.status == RuntimeStatus.RetirementBlocked) {
						mutex.release();
						return;
					}
					mutex.release();
					throw error;
				} catch (error:Dynamic) {
					mutex.release();
					throw error;
				}
			}
		}
		mutex.release();
	}

	@:allow(runtime.Runtime)
	function close(dispose:RuntimeModuleHandle->Void):Bool {
		mutex.acquire();
		var current = handle;
		if (current == null) {
			closeGcHandles();
			mutex.release();
			return true;
		}
		closeRequested = true;
		if (borrowers > 0) {
			deferredDispose = dispose;
			mutex.release();
			return false;
		}
		try {
			dispose(current);
			handle = null;
			closeGcHandles();
			mutex.release();
			return true;
		} catch (error:RuntimeError) {
			if (error.status == RuntimeStatus.RetirementBlocked) {
				mutex.release();
				return false;
			}
			mutex.release();
			throw error;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}

	function closeGcHandles():Void {
		for (handle in gcHandles)
			handle.close();
		gcHandles.resize(0);
	}
}
