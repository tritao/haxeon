package haxeon.platform;

import haxe.Int64;
import haxeon.platform.DisposalRegistration;
import haxeon.platform.NativeKitError;
import haxeon.platform.SurfaceFrameTiming;
import haxeon.platform.SurfaceFrameSubscription;
import haxeon.platform.Window;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Result;
import nativekit.ffi.NativeKitTypes.OwnedSurfaceHandle;
import nativekit.ffi.NativeKitTypes.SurfaceFrameCallbackCallback;
import nativekit.ffi.NativeKitTypes.SurfaceHandle;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.SurfaceFrameMode;
import nativekit.ffi.NativeKitTypes.SurfaceFrameTarget;

/** Owns one graphics surface attached to a NativeKit window. */
class Surface implements Disposable {
	final value:SurfaceHandle;
	final ownsHandle:Bool;
	var disposed:Bool = false;
	var owner:Null<DisposalRegistration>;
	final dependents = new haxeon.platform.internal.DisposalRegistry();
	var frameSubscription:Null<SurfaceFrameSubscription>;

	@:allow(haxeon.platform.Window)
	private function new(value:SurfaceHandle, ownsHandle:Bool) {
		this.value = value;
		this.ownsHandle = ownsHandle;
	}

	/** Creates a non-owning view of a surface managed by a raw NativeKit host. */
	public static function borrowNativeHandle(value:SurfaceHandle):Surface {
		if (!value.isValid())
			throw BindingError.invalidArgument("Surface.borrowNativeHandle",
				"Cannot borrow a null NativeKit surface handle");
		return new Surface(value, false);
	}

	@:allow(haxeon.platform.Window)
	private static function adopt(owned:OwnedSurfaceHandle):Surface
		return new Surface(owned.borrow(), true);

	/** Whether a platform event came from this surface. */
	public function ownsEventSource(source:Handle):Bool
		return !disposed && source.rawValue() == value.rawValue();

	public function nativeHandle():SurfaceHandle {
		ensureLive();
		return value;
	}

	/** Replaces the current frame handler and roots it until dispose/detach succeeds. */
	public function onFrame(handler:Int->Int->Void):SurfaceFrameSubscription {
		ensureLive();
		clearFrameCallback();
		var handlerBridge = new SurfaceFrameHandler(handler);
		var callback = new SurfaceFrameCallbackCallback(handlerBridge.invoke);
		try
			NativeKit.nk_surface_set_frame_callback_checked(value, callback, null)
		catch (error:Dynamic) {
			callback.close();
			throw error;
		}
		var subscription = new SurfaceFrameSubscription(this, callback);
		frameSubscription = subscription;
		return subscription;
	}

	/** Acquires the surface target for render-executor submission. */
	public function acquireFrame():SurfaceFrame {
		ensureLive();
		var target = new SurfaceFrameTarget();
		target.set_struct_size(SurfaceFrameTarget.size());
		var acquired = NativeKit.nk_surface_acquire_frame(value, target);
		if (acquired.status != Result.Ok)
			throw new NativeKitError(acquired.status, "surface.acquireFrame", NativeKit.nk_last_error());
		return new SurfaceFrame(this, acquired.out_frame, acquired.out_target);
	}

	/** Captures timing for the current frame callback. Backends may omit a presentation ID. */
	public function captureFrameTiming(?callbackSeconds:Float):SurfaceFrameTiming {
		ensureLive();
		var started = callbackSeconds == null ? Sys.monotonicTime() : callbackSeconds;
		var feedback = NativeKit.nk_surface_get_presentation_feedback(value, Int64.ofInt(-1));
		if (feedback.status == Result.ErrorUnsupported)
			return new SurfaceFrameTiming(this, null, started);
		if (feedback.status != Result.Ok)
			throw new NativeKitError(feedback.status, "surface.captureFrameTiming", NativeKit.nk_last_error());
		return new SurfaceFrameTiming(this, feedback.out_frame_id, started);
	}

	@:allow(haxeon.platform.SurfaceFrameTiming)
	function presentationSeconds(frameId:Int64):Null<Float> {
		if (disposed)
			return null;
		var feedback = NativeKit.nk_surface_get_presentation_feedback(value, frameId);
		if (feedback.status == Result.ErrorUnsupported)
			return null;
		if (feedback.status != Result.Ok)
			throw new NativeKitError(feedback.status, "surface.presentationSeconds", NativeKit.nk_last_error());
		return feedback.out_presentation_seconds > 0.0 ? feedback.out_presentation_seconds : null;
	}

	/** Detaches the installed frame handler, if any. */
	public function clearFrameCallback():Void {
		ensureLive();
		if (frameSubscription != null)
			frameSubscription.dispose();
	}

	/** Selects continuous or on-demand callbacks for this surface. */
	public function setFrameMode(mode:SurfaceFrameMode):Void {
		ensureLive();
		NativeKit.nk_surface_set_frame_mode_checked(value, mode);
	}

	/** Queues a redraw, including when the surface is in on-demand mode. */
	public function requestFrame():Void {
		ensureLive();
		NativeKit.nk_surface_request_frame_checked(value);
	}

	/** Registers a resource that must be released before this surface. */
	public function registerDependent(release:Void->Void):DisposalRegistration {
		ensureLive();
		return dependents.register(release);
	}

	@:allow(haxeon.gpu.Surface)
	function releaseDependents():Void
		dependents.releaseAll();

	public function dispose():Void {
		if (disposed)
			return;
		clearFrameCallback();
		releaseDependents();
		if (ownsHandle)
			NativeKit.nk_surface_destroy_checked(value);
		disposed = true;
		if (owner != null) owner.detach();
	}

	/** Releases a borrowed wrapper without destroying its host-owned surface. */
	public function releaseBorrowed():Void {
		if (ownsHandle)
			throw BindingError.invalidState("Surface.releaseBorrowed",
				"Cannot release a borrowed view of an owned NativeKit surface");
		dispose();
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.platform.SurfaceFrameSubscription)
	function detach(subscription:SurfaceFrameSubscription):Void {
		if (frameSubscription != subscription) {
			subscription.releasedAfterDetach();
			return;
		}
		NativeKit.nk_surface_set_frame_callback_checked(value, null, null);
		frameSubscription = null;
		subscription.releasedAfterDetach();
	}

	@:allow(haxeon.platform.Window)
	function attachOwner(registration:DisposalRegistration):Void owner = registration;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Surface.ensureLive", "NativeKit surface has been disposed");
	}
}

/** Adapts NativeKit's full ABI callback to the ergonomic size-only surface callback. */
private class SurfaceFrameHandler {
	final handler:Int->Int->Void;

	public function new(handler:Int->Int->Void)
		this.handler = handler;

	public function invoke(_surface:SurfaceHandle, width:Int, height:Int,
			_userData:Null<hl.Abstract<"native_pointer">>):Void
		handler(width, height);
}
