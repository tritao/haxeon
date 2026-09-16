package runtime;

import haxe.io.Bytes;
import compiler.hl.HlModule;
#if haxeon
import compiler.hl.HlNativeMetadataBuilder;
#end
import compiler.hl.HlPatchPolicy;
import compiler.hl.HlRuntimeCallPolicy;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlRuntimeIdentity.HlRuntimeManifest;
#if haxeon
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlRuntimeModuleKernel;
import runtime.memory.RawPtr;
#end
import sys.thread.Mutex;

/**
 * Checked host facade for loading, invoking, patching, and disposing live modules.
 * Calls translate native status codes and exceptions into {@link RuntimeError}.
 */
class Runtime {
	/** Integer lifecycle codes for the Haxe-owned JIT generation side ledger. */
	public static inline var JitGenerationPublished:Int = 1;

	public static inline var JitGenerationRetiring:Int = 2;

	static final retirementBacklog:Array<LoadedModule> = [];
	static final retirementMutex = new Mutex();
	static final jitBackend = new NativeRuntimeJitBackend();
	#if haxeon
	static final haxePatchCoordinator = new HaxeRuntimePatchCoordinator(jitBackend);
	static final haxeRuntimeModuleKernel:HlRuntimeModuleKernel = new NativeHlRuntimeModuleKernel();
	#end

	public static var pendingRetirementCount(get, never):Int;

	static function get_pendingRetirementCount():Int {
		retirementMutex.acquire();
		#if haxeon
		var count = retirementBacklog.length + haxeRuntimeModuleKernel.failedRetirementCount();
		#else
		var count = retirementBacklog.length + RuntimeKernel.failed_retirement_count();
		#end
		retirementMutex.release();
		return count;
	}

	public static function inspectPatch(bytes:Bytes):{baseRevision:Int, revision:Int, functionCount:Int} {
		#if haxeon
		var summary = haxeRuntimeModuleKernel.inspectPatch(cast bytes.getData(), bytes.length);
		#else
		var summary = RuntimeKernel.inspect_patch(bytes.getData(), bytes.length);
		#end
		if (summary < 0)
			throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the HLP bytes");
		return {baseRevision: summary >>> 22, revision: (summary >>> 12) & 0x3FF, functionCount: summary & 0xFFF};
	}

	public static function load(bytes:Bytes, identity:Bytes):LoadedModule {
		var model:HlModule, identityModel:HlRuntimeManifest;
		try {
			model = HlModule.decode(bytes);
			identityModel = validateIdentity(HlRuntimeIdentity.decode(identity), model);
		} catch (error:Dynamic) {
			throw new RuntimeError(RuntimeStatus.BadFormat, 'Haxeon rejected the HLB module: ${Std.string(error)}');
		}
		retryRetirements();
		#if haxeon
		var metadata:HlMetadataGeneration;
		try {
			metadata = HlNativeMetadataBuilder.buildModule(model);
		} catch (error:Dynamic) {
			throw new RuntimeError(RuntimeStatus.BadFormat, 'Haxeon rejected the native metadata: ${Std.string(error)}');
		}
		var publication = metadata.snapshot(),
			count = identityModel.entries.length,
			stableIdStorage:RawPtr<Int32> = count == 0 ? RawPtr.nullPtr() : metadata.arena.allocInt32Array(count),
			slotStorage:RawPtr<Int32> = count == 0 ? RawPtr.nullPtr() : metadata.arena.allocInt32Array(count);
		for (index in 0...count) {
			var entry = identityModel.entries[index];
			stableIdStorage.offset(index).store(cast entry.stableId);
			slotStorage.offset(index).store(cast entry.functionIndex);
		}
		var module = haxeRuntimeModuleKernel.loadCodeManifest(publication.nativeCode, bytes, identityModel.moduleId, identityModel.revision, stableIdStorage,
			slotStorage, count, identityModel.initializerSlot);
		if (module == null) {
			metadata.dispose();
			throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the Haxe-owned module metadata");
		}
		try {
			return new LoadedModule(module, model, identityModel, metadata);
		} catch (error:Dynamic) {
			#if haxeon
			haxeRuntimeModuleKernel.dispose(cast module);
			#else
			RuntimeKernel.dispose(module);
			#end
			metadata.dispose();
			throw error;
		}
		#else
		retryRetirements();
		var module = RuntimeKernel.load(bytes.getData(), bytes.length, identity.getData(), identity.length);
		if (module == null)
			throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the module bytes");
		return new LoadedModule(module, model, identityModel);
		#end
	}

	static function validateIdentity(identity:HlRuntimeManifest, model:HlModule):HlRuntimeManifest {
		var initializerEntry = identity.initializerSlot < 0;
		for (entry in identity.entries)
			if (model.functionAt(entry.functionIndex) == null)
				throw 'HLI identity references missing dispatch slot ${entry.functionIndex}';
			else if (entry.functionIndex == identity.initializerSlot)
				initializerEntry = true;
		if (!initializerEntry)
			throw 'HLI initializer references a slot absent from the identity table';
		return identity;
	}

	public static function callInt(module:LoadedModule, stableIndex:Int):Int
		return invoke(module, stableIndex, 0, function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.callI32(cast handle, stableIndex);
			#else
			return RuntimeKernel.call_i32(handle, stableIndex);
			#end
		});

	public static function callVoid(module:LoadedModule, stableIndex:Int):Void
		invoke(module, stableIndex, 1, function(handle) {
			#if haxeon
			haxeRuntimeModuleKernel.callVoid(cast handle, stableIndex);
			#else
			RuntimeKernel.call_void(handle, stableIndex);
			#end
		});

	public static function callString(module:LoadedModule, stableIndex:Int):String {
		var bytes = invoke(module, stableIndex, 2, function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.callBytes(cast handle, stableIndex);
			#else
			return RuntimeKernel.call_bytes(handle, stableIndex);
			#end
		});
		if (bytes == null)
			return null;
		return @:privateAccess String.__alloc__(bytes, bytes.ucs2Length(0));
	}

	public static function callStringArg(module:LoadedModule, stableIndex:Int, argument:String):Void
		invoke(module, stableIndex, 3, function(handle) {
			#if haxeon
			haxeRuntimeModuleKernel.callBytes1(cast handle, stableIndex, cast @:privateAccess argument.bytes);
			#else
			RuntimeKernel.call_bytes1(handle, stableIndex, @:privateAccess argument.bytes);
			#end
		});

	public static function retainClosure(module:LoadedModule, stableIndex:Int):RetainedValue
		return new RetainedValue(module, retain(module, stableIndex, 4, function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.callClosure(cast handle, stableIndex);
			#else
			return RuntimeKernel.call_closure(handle, stableIndex);
			#end
		}));

	public static function callRetainedClosureInt(closure:RetainedValue):Int
		#if haxeon
		return closure.access(function(handle, retained) return haxeRuntimeModuleKernel.callClosureI32(cast handle, retained));
		#else
		return closure.access(RuntimeKernel.call_closure_i32);
		#end

	public static function retainObject(module:LoadedModule, stableIndex:Int):RetainedValue
		return new RetainedValue(module, retain(module, stableIndex, 5, function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.callObject(cast handle, stableIndex);
			#else
			return RuntimeKernel.call_object(handle, stableIndex);
			#end
		}));

	public static function callIntObject(module:LoadedModule, stableIndex:Int, argument:RetainedValue):Int
		return invoke(module, stableIndex, 6, function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.callI32Object(cast handle, stableIndex, argument.get());
			#else
			return RuntimeKernel.call_i32_object(handle, stableIndex, argument.get());
			#end
		});

	public static function retainedCodeAllocationCount(module:LoadedModule):Int
		return module.access(jitBackend.retainedCodeAllocationCount);

	public static function patchJitCount(module:LoadedModule):Int
		return module.access(jitBackend.patchCount);

	/** Return the number of Haxe-owned patch generations no longer owning a function. */
	public static function retiredPatchCount(module:LoadedModule):Int
		return module.retiredPatchCount();

	/** Resolve the currently published JIT target to its function/opcode location. */
	public static function jitLocation(module:LoadedModule, stableIndex:Int):Null<String> {
		var bytes = module.access(function(handle) return jitBackend.location(handle, stableIndex));
		return bytes == null ? null : @:privateAccess String.__alloc__(bytes, bytes.ucs2Length(0));
	}

	public static function debugRegionCount(module:LoadedModule):Int
		return module.access(jitBackend.debugRegionCount);

	public static function retiredCodeAllocationCount(module:LoadedModule):Int
		return module.access(jitBackend.retiredCodeAllocationCount);

	/** Return the Haxe-side lifecycle code for one live JIT generation record. */
	public static function jitGenerationState(module:LoadedModule, index:Int):Int {
		return module.jitGenerationState(index);
	}

	/** Return the native revision held by one Haxe-owned JIT generation record. */
	public static function jitGenerationRevision(module:LoadedModule, index:Int):Int {
		return module.jitGenerationRevision(index);
	}

	public static function metadataTypeCount(module:LoadedModule):Int
		return module.access(function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.typeCount(cast handle);
			#else
			return RuntimeKernel.type_count(handle);
			#end
		});

	public static function metadataTypeCapacity(module:LoadedModule):Int
		return module.access(function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.typeCapacity(cast handle);
			#else
			return RuntimeKernel.type_capacity(handle);
			#end
		});

	public static function liveAllocationCount(module:LoadedModule):Int
		return module.access(function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.liveAllocationCount(cast handle);
			#else
			return RuntimeKernel.live_allocation_count(handle);
			#end
		});

	public static function nativeRootCount(module:LoadedModule):Int
		return module.access(function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.nativeRootCount(cast handle);
			#else
			return RuntimeKernel.native_root_count(handle);
			#end
		});

	public static function retirementStatus(module:LoadedModule):ModuleRetirementStatus
		return module.access(function(handle) {
			// Native ABI: four consecutive little-endian Int32 fields in declaration order.
			var bytes = Bytes.alloc(16);
			#if haxeon
			haxeRuntimeModuleKernel.retirementStatus(cast handle, cast bytes.getData());
			#else
			RuntimeKernel.retirement_status(handle, bytes.getData());
			#end
			return new ModuleRetirementStatus(bytes.getInt32(0), bytes.getInt32(4), bytes.getInt32(8), bytes.getInt32(12));
		});

	public static function liveRevision(module:LoadedModule):Int
		return module.access(function(handle) {
			#if haxeon
			return haxeRuntimeModuleKernel.revision(cast handle);
			#else
			return RuntimeKernel.revision(handle);
			#end
		});

	@:noCompletion public static function injectPatchFailure(module:LoadedModule, stage:Int):Void
		module.access(function(handle) {
			#if haxeon
			haxeRuntimeModuleKernel.setPatchFailureStage(cast handle, stage);
			#else
			jitBackend.injectPatchFailure(handle, stage);
			#end
		});

	public static function dispose(module:LoadedModule):Void {
		retirementMutex.acquire();
		try {
			if (!tryDispose(module) && retirementBacklog.indexOf(module) < 0)
				retirementBacklog.push(module);
			retirementMutex.release();
		} catch (error:Dynamic) {
			retirementMutex.release();
			throw error;
		}
	}

	/** Retry modules whose reclamation was delayed by retained or conservative borrowers. */
	public static function retryRetirements():Int {
		retirementMutex.acquire();
		try {
			var write = 0;
			for (read in 0...retirementBacklog.length) {
				var module = retirementBacklog[read];
				if (!tryDispose(module))
					retirementBacklog[write++] = module;
			}
			retirementBacklog.resize(write);
			#if haxeon
			write += haxeRuntimeModuleKernel.retryFailedRetirements();
			#else
			write += RuntimeKernel.retry_failed_retirements();
			#end
			retirementMutex.release();
			return write;
		} catch (error:Dynamic) {
			retirementMutex.release();
			throw error;
		}
	}

	/** Reclaim every pending module or report that shutdown still has borrowers. */
	public static function drainRetirements():Void {
		var pending = retryRetirements();
		if (pending != 0)
			throw new RuntimeError(RuntimeStatus.RetirementBlocked, '$pending runtime module retirement(s) remain blocked');
	}

	static function tryDispose(module:LoadedModule):Bool {
		var disposed = module.close(function(handle) {
			#if haxeon
			var status:RuntimeStatus = haxeRuntimeModuleKernel.dispose(cast handle);
			#else
			var status:RuntimeStatus = RuntimeKernel.dispose(handle);
			#end
			if (status != RuntimeStatus.Ok)
				throw new RuntimeError(status,
					status == RuntimeStatus.RetirementBlocked ? "Runtime module retirement is waiting for managed borrowers" : 'HashLink rejected module retirement (status ${(status : Int)})');
		});
		if (disposed) {
			finishJitRetirement(module);
			#if haxeon
			finishMetadataRetirement(module);
			#end
		} else
			beginJitRetirement(module);
		return disposed;
	}

	public static function patchSet(module:LoadedModule, patch:PatchSet):Void {
		stagePatch(module, patch).commit();
	}

	/** Stage a host-runtime HLP update for explicit commit or rollback. */
	public static function stagePatch(module:LoadedModule, patch:PatchSet):RuntimePatchTransaction
		return new RuntimePatchTransaction(module, patch);

	/** Commit one staged host transaction while holding the module mutex. */
	@:allow(runtime.RuntimePatchTransaction)
	static function commitPatch(transaction:RuntimePatchTransaction):Void {
		#if haxeon
		var status:RuntimeStatus = haxePatchCoordinator.commit(transaction);
		#else
		var module = transaction.owner,
			envelope = transaction.envelope,
			decoded = transaction.model;
		var status:RuntimeStatus = module.access(function(handle) {
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
		#end
		if (status != RuntimeStatus.Ok) {
			var statusCode:Int = status;
			throw new RuntimeError(status, 'HashLink rejected the patch transaction (status $statusCode)');
		}
	}

	static function invoke<T>(module:LoadedModule, stableIndex:Int, shape:Int, operation:RuntimeModuleHandle->T):T
		return module.access(function(handle) {
			validateCall(module, handle, stableIndex, shape);
			try {
				return operation(handle);
			} catch (error:RuntimeError) {
				throw error;
			} catch (error:Dynamic) {
				throw new RuntimeError(RuntimeStatus.Exception, Std.string(error));
			}
		});

	static function retain(module:LoadedModule, stableIndex:Int, shape:Int, operation:RuntimeModuleHandle->Dynamic):Dynamic
		return module.accessRetained(function(handle) {
			validateCall(module, handle, stableIndex, shape);
			try {
				return operation(handle);
			} catch (error:RuntimeError) {
				throw error;
			} catch (error:Dynamic) {
				throw new RuntimeError(RuntimeStatus.Exception, Std.string(error));
			}
		});

	/** Haxeon owns the immutable module/identity policy; native code rechecks live dispatch state. */
	static function validateCall(module:LoadedModule, handle:RuntimeModuleHandle, stableIndex:Int, shape:Int):Void {
		validateCallModel(module, stableIndex, shape);
		#if haxeon
		var status:RuntimeStatus = haxeRuntimeModuleKernel.validateCall(cast handle, stableIndex, shape);
		#else
		var status:RuntimeStatus = RuntimeKernel.validate_call(handle, stableIndex, shape);
		#end
		if (status != RuntimeStatus.Ok)
			throw new RuntimeError(status, 'Invalid runtime function call (stable ID $stableIndex)');
	}

	static function validateCallModel(module:LoadedModule, stableIndex:Int, shape:Int):Void {
		if (!HlRuntimeCallPolicy.validShape(shape))
			throw new RuntimeError(RuntimeStatus.BadArgument, 'Invalid runtime call shape $shape');
		if (!HlRuntimeCallPolicy.validFunction(module.model, module.identity, stableIndex, shape))
			throw new RuntimeError(RuntimeStatus.BadFunction, 'Invalid runtime function call (stable ID $stableIndex)');
	}

	#if haxeon
	static function finishMetadataRetirement(module:LoadedModule):Void {
		module.metadata.dispose();
	}
	#end

	static function beginJitRetirement(module:LoadedModule):Void {
		module.beginJitRetirement();
	}

	static function finishJitRetirement(module:LoadedModule):Void {
		module.finishJitRetirement();
	}
}
