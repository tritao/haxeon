package runtime;

import compiler.hl.HlModule;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
#if haxeon
import runtime.hashlink.HlMetadataGeneration;
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

	#if haxeon
	/** Haxe-owned native metadata retained for the lifetime of this module. */
	public final metadata:HlMetadataGeneration;
	#end

	final mutex = new Mutex();
	var handle:Null<RuntimeModuleHandle>;
	var closeRequested = false;
	var borrowers = 0;
	var deferredDispose:Null<RuntimeModuleHandle->Void>;

	@:allow(runtime.Runtime)
	function new(handle:RuntimeModuleHandle, model:HlModule, identity:HlRuntimeManifest #if haxeon, metadata:HlMetadataGeneration #end) {
		#if haxeon
		if (metadata == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Haxeon runtime modules require an owned metadata generation");
		this.metadata = metadata;
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

	/** Number of successfully published Haxe-owned patch generations. */
	public inline function committedPatchCount():Int
		return patchState.committedPatchCount();

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
	@:allow(runtime.Runtime)
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
	@:allow(runtime.Runtime)
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

	@:allow(runtime.Runtime)
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
}
