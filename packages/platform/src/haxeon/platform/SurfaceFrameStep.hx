package haxeon.platform;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.SurfaceFrameStepHandle;

/** Owns module-prepared frame work until it is submitted or disposed. */
class SurfaceFrameStep implements Disposable {
	final handle:SurfaceFrameStepHandle;
	var consumed = false;

	@:allow(haxeon.gpu.Batch, haxeon.ui.LayoutSession, haxeon.ui.Renderer)
	function new(handle:SurfaceFrameStepHandle) this.handle = handle;

	@:allow(haxeon.platform.SurfaceFrame)
	function nativeHandle():SurfaceFrameStepHandle {
		if (consumed)
			throw BindingError.invalidState("SurfaceFrameStep", "Frame step was already consumed");
		return handle;
	}

	@:allow(haxeon.platform.SurfaceFrame)
	function submitted():Void consumed = true;

	public function dispose():Void {
		if (consumed)
			return;
		NativeKit.nk_surface_frame_step_destroy_checked(handle);
		consumed = true;
	}
}
