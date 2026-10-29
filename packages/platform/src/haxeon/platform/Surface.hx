package haxeon.platform;

import haxeon.platform.DisposalRegistration;
import haxeon.platform.SurfaceFrameSubscription;
import haxeon.platform.Window;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.OwnedSurfaceHandle;
import nativekit.ffi.NativeKitTypes.SurfaceFrameCallbackCallback;
import nativekit.ffi.NativeKitTypes.SurfaceHandle;

/** Owns one graphics surface attached to a NativeKit window. */
class Surface {
	final value:SurfaceHandle;
	final ownsHandle:Bool;
	var disposed:Bool = false;
	var owner:Null<DisposalRegistration>;
	var frameSubscription:Null<SurfaceFrameSubscription>;

	@:allow(Window)
	private function new(value:SurfaceHandle, ownsHandle:Bool) {
		this.value = value;
		this.ownsHandle = ownsHandle;
	}

	/** Creates a non-owning view of a surface managed by a raw NativeKit host. */
	public static function borrowNativeHandle(value:SurfaceHandle):Surface {
		if (!value.isValid())
			throw BindingError.invalidArgument("Surface.borrowNativeHandle", "Cannot borrow a null NativeKit surface handle");
		return new Surface(value, false);
	}

	@:allow(Window)
	private static function adopt(owned:OwnedSurfaceHandle):Surface
		return new Surface(owned.borrow(), true);

	public function nativeHandle():SurfaceHandle {
		ensureLive();
		return value;
	}

	/** Replaces the current frame handler and roots it until dispose/detach succeeds. */
	public function onFrame(handler:Int->Int->Void):SurfaceFrameSubscription {
		ensureLive();
		if (frameSubscription != null)
			frameSubscription.dispose();
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

	public function dispose():Void {
		if (disposed)
			return;
		if (frameSubscription != null)
			frameSubscription.dispose();
		if (ownsHandle)
			NativeKit.nk_surface_destroy_checked(value);
		disposed = true;
		if (owner != null) owner.detach();
	}

	/** Releases a borrowed wrapper without destroying its host-owned surface. */
	public function releaseBorrowed():Void {
		if (ownsHandle)
			throw BindingError.invalidState("Surface.releaseBorrowed", "Cannot release a borrowed view of an owned NativeKit surface");
		dispose();
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(SurfaceFrameSubscription)
	function detach(subscription:SurfaceFrameSubscription):Void {
		if (frameSubscription != subscription) {
			subscription.releasedAfterDetach();
			return;
		}
		NativeKit.nk_surface_set_frame_callback_checked(value, null, null);
		frameSubscription = null;
		subscription.releasedAfterDetach();
	}

	@:allow(Window)
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
