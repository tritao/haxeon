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

	public static function patch(module:hl.Abstract<"realtime_module">, bytes:hl.Bytes, length:Int):Int
		return -1;

	public static function allocation_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function patch_jit_count(module:hl.Abstract<"realtime_module">):Int
		return 0;

	public static function dispose(module:hl.Abstract<"realtime_module">):Void {}

	public static function inspect_patch(bytes:hl.Bytes, length:Int):Int
		return -1;
}

class Runtime {
	public static function inspectPatch(bytes:Bytes):{baseRevision:Int, revision:Int, functionCount:Int} {
		var summary = RuntimeNative.inspect_patch(bytes.getData(), bytes.length);
		if (summary < 0)
			throw "HashLink rejected the HLP bytes";
		return {baseRevision: summary >>> 22, revision: (summary >>> 12) & 0x3FF, functionCount: summary & 0xFFF};
	}

	public static function load(bytes:Bytes, identity:Bytes):LoadedModule {
		var module = RuntimeNative.load(bytes.getData(), bytes.length, identity.getData(), identity.length);
		if (module == null)
			throw "HashLink rejected the module bytes";
		return cast module;
	}

	public static function callInt(module:LoadedModule, stableIndex:Int):Int
		return RuntimeNative.call_i32(cast module, stableIndex);

	public static function callVoid(module:LoadedModule, stableIndex:Int):Void
		RuntimeNative.call_void(cast module, stableIndex);

	public static function callString(module:LoadedModule, stableIndex:Int):String {
		var bytes = RuntimeNative.call_bytes(cast module, stableIndex);
		if (bytes == null)
			return null;
		return @:privateAccess String.__alloc__(bytes, bytes.ucs2Length(0));
	}

	public static function callStringArg(module:LoadedModule, stableIndex:Int, argument:String):Void
		RuntimeNative.call_bytes1(cast module, stableIndex, @:privateAccess argument.bytes);

	public static function retainedCodeAllocationCount(module:LoadedModule):Int
		return RuntimeNative.allocation_count(cast module);

	public static function patchJitCount(module:LoadedModule):Int
		return RuntimeNative.patch_jit_count(cast module);

	public static function dispose(module:LoadedModule):Void
		RuntimeNative.dispose(cast module);

	public static function patchSet(module:LoadedModule, patch:PatchSet):Void {
		var status:RuntimeStatus = RuntimeNative.patch(cast module, patch.bytes.getData(), patch.bytes.length);
		if (status != RuntimeStatus.Ok) {
			var statusCode:Int = status;
			throw new RuntimeError(status, 'HashLink rejected the patch transaction (status $statusCode)');
		}
	}
}
