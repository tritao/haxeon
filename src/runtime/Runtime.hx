package runtime;

import haxe.io.Bytes;

@:hlNative("realtime_runtime")
private class RuntimeNative {
	public static function load(bytes:hl.Bytes, length:Int, identity:hl.Bytes, identityLength:Int):hl.Abstract<"realtime_module">
		return null;

	public static function call_i32(module:hl.Abstract<"realtime_module">, index:Int):Int
		return 0;

	public static function call_void(module:hl.Abstract<"realtime_module">, index:Int):Void {}

	public static function call_bytes(module:hl.Abstract<"realtime_module">, index:Int):hl.Bytes
		return null;

	public static function call_bytes1(module:hl.Abstract<"realtime_module">, index:Int, argument:hl.Bytes):Void {}

	public static function call_closure(module:hl.Abstract<"realtime_module">, index:Int):Dynamic
		return null;

	public static function call_closure_i32(closure:Dynamic):Int
		return 0;

	public static function call_object(module:hl.Abstract<"realtime_module">, index:Int):Dynamic
		return null;

	public static function call_i32_object(module:hl.Abstract<"realtime_module">, index:Int, argument:Dynamic):Int
		return 0;

	public static function validate_call(module:hl.Abstract<"realtime_module">, index:Int, shape:Int):Int
		return -1;

	public static function patch(module:hl.Abstract<"realtime_module">, bytes:hl.Bytes, length:Int):Int
		return -1;

	public static function allocation_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function patch_jit_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function retired_allocation_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function type_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function type_capacity(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function revision(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function set_patch_failure_stage(module:hl.Abstract<"realtime_module">, stage:Int):Void {}

	public static function dispose(module:hl.Abstract<"realtime_module">):Void {}

	public static function inspect_patch(bytes:hl.Bytes, length:Int):Int
		return -1;
}

class Runtime {
	public static function inspectPatch(bytes:Bytes):{baseRevision:Int, revision:Int, functionCount:Int} {
		var summary = RuntimeNative.inspect_patch(bytes.getData(), bytes.length);
		if (summary < 0)
			throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the HLP bytes");
		return {baseRevision: summary >>> 22, revision: (summary >>> 12) & 0x3FF, functionCount: summary & 0xFFF};
	}

	public static function load(bytes:Bytes, identity:Bytes):LoadedModule {
		var module = RuntimeNative.load(bytes.getData(), bytes.length, identity.getData(), identity.length);
		if (module == null)
			throw new RuntimeError(RuntimeStatus.BadFormat, "HashLink rejected the module bytes");
		return new LoadedModule(module);
	}

	public static function callInt(module:LoadedModule, stableIndex:Int):Int
		return invoke(module, stableIndex, 0, function(handle) return RuntimeNative.call_i32(handle, stableIndex));

	public static function callVoid(module:LoadedModule, stableIndex:Int):Void
		invoke(module, stableIndex, 1, function(handle) RuntimeNative.call_void(handle, stableIndex));

	public static function callString(module:LoadedModule, stableIndex:Int):String {
		var bytes = invoke(module, stableIndex, 2, function(handle) return RuntimeNative.call_bytes(handle, stableIndex));
		if (bytes == null)
			return null;
		return @:privateAccess String.__alloc__(bytes, bytes.ucs2Length(0));
	}

	public static function callStringArg(module:LoadedModule, stableIndex:Int, argument:String):Void
		invoke(module, stableIndex, 3, function(handle) RuntimeNative.call_bytes1(handle, stableIndex, @:privateAccess argument.bytes));

	public static function retainClosure(module:LoadedModule, stableIndex:Int):RetainedValue
		return new RetainedValue(module, retain(module, stableIndex, 4, function(handle) return RuntimeNative.call_closure(handle, stableIndex)));

	public static function callRetainedClosureInt(closure:RetainedValue):Int
		return RuntimeNative.call_closure_i32(closure.get());

	public static function retainObject(module:LoadedModule, stableIndex:Int):RetainedValue
		return new RetainedValue(module, retain(module, stableIndex, 5, function(handle) return RuntimeNative.call_object(handle, stableIndex)));

	public static function callIntObject(module:LoadedModule, stableIndex:Int, argument:RetainedValue):Int
		return invoke(module, stableIndex, 6, function(handle) return RuntimeNative.call_i32_object(handle, stableIndex, argument.get()));

	public static function retainedCodeAllocationCount(module:LoadedModule):Int
		return module.access(RuntimeNative.allocation_count);

	public static function patchJitCount(module:LoadedModule):Int
		return module.access(RuntimeNative.patch_jit_count);

	public static function retiredCodeAllocationCount(module:LoadedModule):Int
		return module.access(RuntimeNative.retired_allocation_count);

	public static function metadataTypeCount(module:LoadedModule):Int
		return module.access(RuntimeNative.type_count);

	public static function metadataTypeCapacity(module:LoadedModule):Int
		return module.access(RuntimeNative.type_capacity);

	public static function liveRevision(module:LoadedModule):Int
		return module.access(RuntimeNative.revision);

	@:noCompletion public static function injectPatchFailure(module:LoadedModule, stage:Int):Void
		module.access(function(handle) RuntimeNative.set_patch_failure_stage(handle, stage));

	public static function dispose(module:LoadedModule):Void
		module.close(RuntimeNative.dispose);

	public static function patchSet(module:LoadedModule, patch:PatchSet):Void {
		var status:RuntimeStatus = module.access(function(handle) return RuntimeNative.patch(handle, patch.bytes.getData(), patch.bytes.length));
		if (status != RuntimeStatus.Ok) {
			var statusCode:Int = status;
			throw new RuntimeError(status, 'HashLink rejected the patch transaction (status $statusCode)');
		}
	}

	static function invoke<T>(module:LoadedModule, stableIndex:Int, shape:Int, operation:hl.Abstract<"realtime_module">->T):T
		return module.access(function(handle) {
			validateCall(handle, stableIndex, shape);
			try
				return operation(handle)
			catch (error:RuntimeError)
				throw error
			catch (error:Dynamic)
				throw new RuntimeError(RuntimeStatus.Exception, Std.string(error));
		});

	static function retain(module:LoadedModule, stableIndex:Int, shape:Int, operation:hl.Abstract<"realtime_module">->Dynamic):Dynamic
		return module.accessRetained(function(handle) {
			validateCall(handle, stableIndex, shape);
			try
				return operation(handle)
			catch (error:RuntimeError)
				throw error
			catch (error:Dynamic)
				throw new RuntimeError(RuntimeStatus.Exception, Std.string(error));
		});

	static function validateCall(handle:hl.Abstract<"realtime_module">, stableIndex:Int, shape:Int):Void {
		var status:RuntimeStatus = RuntimeNative.validate_call(handle, stableIndex, shape);
		if (status != RuntimeStatus.Ok)
			throw new RuntimeError(status, 'Invalid runtime function call (stable ID $stableIndex)');
	}
}
