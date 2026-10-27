package haxeon.platform;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Owns one graphics surface attached to a NativeKit window. */
class NativeKitSurface {
	final value:SurfaceHandle;
	final ownsHandle:Bool;
	var disposed:Bool = false;
	var owner:Null<NativeResourceRegistry.NativeResourceRegistration>;
	var frameSubscription:Null<NativeKitSurfaceFrameSubscription>;

	@:allow(NativeKitWindow)
	private function new(value:SurfaceHandle, ownsHandle:Bool) {
		this.value = value;
		this.ownsHandle = ownsHandle;
	}

	/** Creates a non-owning view of a surface managed by a raw NativeKit host. */
	public static function borrowNativeHandle(value:SurfaceHandle):NativeKitSurface {
		if (!value.isValid())
			throw "Cannot borrow a null NativeKit surface handle";
		return new NativeKitSurface(value, false);
	}

	@:allow(NativeKitWindow)
	private static function adopt(owned:OwnedSurfaceHandle):NativeKitSurface
		return new NativeKitSurface(owned.borrow(), true);

	public function nativeHandle():SurfaceHandle {
		ensureLive();
		return value;
	}

	/** Replaces the current frame handler and roots it until dispose/detach succeeds. */
	public function onFrame(handler:Int->Int->Void):NativeKitSurfaceFrameSubscription {
		ensureLive();
		if (frameSubscription != null)
			frameSubscription.dispose();
		var handlerBridge = new NativeKitSurfaceFrameHandler(handler);
		var callback = new SurfaceFrameCallbackCallback(handlerBridge.invoke);
		try
			NativeKit.nk_surface_set_frame_callback_checked(value, callback, null)
		catch (error:Dynamic) {
			callback.close();
			throw error;
		}
		var subscription = new NativeKitSurfaceFrameSubscription(this, callback);
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
			throw "Cannot release a borrowed view of an owned NativeKit surface";
		dispose();
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(NativeKitSurfaceFrameSubscription)
	function detach(subscription:NativeKitSurfaceFrameSubscription):Void {
		if (frameSubscription != subscription) {
			subscription.releasedAfterDetach();
			return;
		}
		NativeKit.nk_surface_set_frame_callback_checked(value, null, null);
		frameSubscription = null;
		subscription.releasedAfterDetach();
	}

	@:allow(NativeKitWindow)
	function attachOwner(registration:NativeResourceRegistry.NativeResourceRegistration):Void owner = registration;

	function ensureLive():Void {
		if (disposed)
			throw "NativeKit surface has been disposed";
	}
}

/** Registration token for one retained NativeKit frame callback. */
class NativeKitSurfaceFrameSubscription {
	final surface:NativeKitSurface;
	final callback:SurfaceFrameCallbackCallback;
	var disposed:Bool = false;

	@:allow(NativeKitSurface)
	private function new(surface:NativeKitSurface, callback:SurfaceFrameCallbackCallback) {
		this.surface = surface;
		this.callback = callback;
	}

	public function dispose():Void {
		if (disposed)
			return;
		surface.detach(this);
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(NativeKitSurface)
	function releasedAfterDetach():Void {
		if (disposed)
			return;
		disposed = true;
		callback.close();
	}

}

/** Adapts NativeKit's full ABI callback to the ergonomic size-only surface callback. */
private class NativeKitSurfaceFrameHandler {
	final handler:Int->Int->Void;

	public function new(handler:Int->Int->Void)
		this.handler = handler;

	public function invoke(_surface:SurfaceHandle, width:Int, height:Int,
		_userData:Null<hl.Abstract<"native_pointer">>):Void
		handler(width, height);
}
