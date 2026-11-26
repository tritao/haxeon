package haxeon.gpu;

import nativekit.ffi.NativeKitGpu;

/** Centralizes raw GPU-adapter result handling for the typed Haxe facade. */
internal class GpuResult {
	public static function check(status:GpuStatus, operation:String):Void {
		if (status != GpuStatus.Ok)
			throw new GpuError(status.rawValue, operation, NativeKitGpu.nkgpu_last_error());
	}
}
