package haxeon.platform;

import haxeon.platform.BindingError;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;


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
	var submitted:Bool = false;
	var presented:Bool = false;

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
			throw NativeKitStatus.failure(status, "surfaceFrame.present", NativeKit.nk_last_error());
		presented = true;
	}

	/** Cancels the frame and releases its platform transaction. */
	public function cancel():Void {
		ensureOpen();
		var status = NativeKit.nk_surface_cancel_frame(value);
		if (status != Result.Ok)
			throw NativeKitStatus.failure(status, "surfaceFrame.cancel", NativeKit.nk_last_error());
		finished = true;
	}

	/** Whether it has been presented or cancelled. */
	public function isFinished():Bool
		return finished;

	@:allow(haxeon.platform.AppLoop)
	function wasSubmitted():Bool
		return submitted;

	@:allow(haxeon.platform.AppLoop)
	function wasPresented():Bool
		return presented;

	/** Identifies this transaction in SurfaceFrameComplete events, including after submission. */
	public function token():haxe.Int64
		return haxe.Int64.make(0, value.rawValue);

	/** Transfers the frame and ordered steps. Listen for SurfaceFrameComplete to get the result. */
	public function submit(steps:Array<SurfaceFrameStep>):Void {
		ensureOpen();
		if (steps == null)
			throw BindingError.invalidArgument("SurfaceFrame.submit", "Frame steps must not be null");
		var handles = [];
		for (step in steps) {
			if (step == null)
				throw BindingError.invalidArgument("SurfaceFrame.submit", "Frame step must not be null");
			handles.push(step.nativeHandle().rawValue);
		}
		NativeKit.nk_surface_frame_submit_checked(value, handles);
		finished = true;
		submitted = true;
		for (step in steps)
			step.submitted();
	}

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

	/** Whether it is a frame of `surface`. */
	public function belongsTo(surface:Surface):Bool
		return this.surface == surface;

	function ensureOpen():Void {
		if (finished)
			throw BindingError.invalidState("SurfaceFrame.ensureOpen", "Surface frame has already finished");
		surface.nativeHandle();
	}
}
