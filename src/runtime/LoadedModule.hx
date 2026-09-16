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

	/** Haxe-owned revision corresponding to the last successful native publication. */
	public var revision(default, null):Int;

	/** Stable function identities and their current Haxe-side generations. */
	public var functions(default, null):RuntimeFunctionVersionTable;

	/** Haxe-owned snapshots of successfully published patch generations. */
	final patchLedger:Array<RuntimePatchGeneration> = [];

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
		this.revision = identity.revision;
		this.functions = functionVersions(model, identity);
	}

	/** Number of successfully published Haxe-owned patch generations. */
	public inline function committedPatchCount():Int
		return patchLedger.length;

	/** Advance Haxe-owned state after the native patch has been published. */
	@:allow(runtime.Runtime)
	function commitPatch(generation:RuntimePatchGeneration):Void {
		if (generation == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime patch state requires a prepared generation");
		var patchModel = generation.patch,
			envelope = generation.envelope,
			nextFunctions = generation.functions;
		if (envelope.baseRevision != revision || envelope.revision <= revision)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime patch state has an invalid revision transition");
		for (value in patchModel.ints)
			model.code.ints.push(value);
		for (value in patchModel.floats)
			model.code.floats.push(value);
		for (value in patchModel.strings)
			model.code.strings.push(value);
		for (type in patchModel.types)
			model.code.types.push(type);
		patchLedger.push(generation);
		functions = nextFunctions;
		revision = envelope.revision;
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
