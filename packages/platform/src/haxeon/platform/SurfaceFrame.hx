package haxeon.platform;

import haxeon.platform.BindingError;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

import haxeon.platform.NativeKitError;

/**
 * Immutable surface target acquired for a deferred render submission.
 *
 * Acquire on the platform executor, submit the batch on the render executor,
 * then present or cancel this frame on the platform executor.
 */
class SurfaceFrame {
	final surface:Surface;
	final value:SurfaceFrameHandle;
	final target:SurfaceFrameTarget;
	var finished:Bool = false;

	@:allow(haxeon.platform.Surface)
	function new(surface:Surface, value:SurfaceFrameHandle, target:SurfaceFrameTarget) {
		this.surface = surface;
		this.value = value;
		this.target = target;
	}

	/** Presents the submitted frame and releases its platform transaction. */
	public function present():Void {
		ensureOpen();
		var status = NativeKit.nk_surface_present_frame(value);
		if (status != Result.ErrorWrongThread) finished = true;
		if (status != Result.Ok)
			throw new NativeKitError(status, "surfaceFrame.present", NativeKit.nk_last_error());
	}

	/** Cancels the frame and releases its platform transaction. */
	public function cancel():Void {
		ensureOpen();
		var status = NativeKit.nk_surface_cancel_frame(value);
		if (status != Result.Ok)
			throw new NativeKitError(status, "surfaceFrame.cancel", NativeKit.nk_last_error());
		finished = true;
	}

	public function isFinished():Bool
		return finished;

	@:allow(haxeon.gpu.Batch)
	function nativeTarget():SurfaceFrameTarget {
		ensureOpen();
		return target;
	}

	/** Native token for render-executor interoperability. */
	public function nativeHandle():SurfaceFrameHandle {
		ensureOpen();
		return value;
	}

	public function belongsTo(surface:Surface):Bool
		return this.surface == surface;

	function ensureOpen():Void {
		if (finished)
			throw BindingError.invalidState("SurfaceFrame.ensureOpen", "Surface frame has already finished");
		surface.nativeHandle();
	}
}
