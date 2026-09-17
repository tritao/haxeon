package runtime.hashlink;

import haxe.io.Bytes;
import runtime.hashlink.HlRuntimeJitBackend.HlRuntimeModuleHandle;

/**
	Compatibility seam for callers that still hand HashLink encoded HLP bytes.
	The Haxe-owned runtime path must use HlRuntimeJitBackend instead.
*/
interface HlLegacyRuntimePatchBackend {
	function patch(module:HlRuntimeModuleHandle, bytes:Bytes):Int;
	function patchCode(module:HlRuntimeModuleHandle, bytes:Bytes):HlRuntimePatchPublication;
	function patchCodeWithHaxeTypes(module:HlRuntimeModuleHandle, bytes:Bytes, typeCount:Int):HlRuntimePatchPublication;
}

/** Native implementation of the legacy byte-oriented patch compatibility seam. */
class NativeHlLegacyRuntimePatchBackend implements HlLegacyRuntimePatchBackend {
	public function new() {}

	public inline function patch(module:HlRuntimeModuleHandle, bytes:Bytes):Int
		return HlTypeBridge.native_runtime_module_patch(module, bytes, bytes.length);

	public inline function patchCode(module:HlRuntimeModuleHandle, bytes:Bytes):HlRuntimePatchPublication {
		var status = Bytes.alloc(4),
			code = HlTypeBridge.native_runtime_module_patch_code(module, bytes, bytes.length, cast status.getData()),
			result = status.getInt32(0);
		return new HlRuntimePatchPublication(result, code);
	}

	public inline function patchCodeWithHaxeTypes(module:HlRuntimeModuleHandle, bytes:Bytes, typeCount:Int):HlRuntimePatchPublication {
		var status = Bytes.alloc(4),
			code = HlTypeBridge.native_runtime_module_patch_code_haxe_types(module, bytes, bytes.length, typeCount, cast status.getData()),
			result = status.getInt32(0);
		return new HlRuntimePatchPublication(result, code);
	}
}
