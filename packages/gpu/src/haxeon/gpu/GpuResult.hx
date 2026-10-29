package haxeon.gpu;

import nativekit.ffi.NativeKitGpu;

/** Centralizes raw GPU-adapter result handling for the typed Haxe facade. */
class GpuResult {
	public static function check(status:Int, operation:String):Void {
		if (status != 0)
			throw new GpuError(status, operation, NativeKitGpu.nkgpu_last_error());
	}
}
