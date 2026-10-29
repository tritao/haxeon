package haxeon.platform;

import haxeon.platform.Surface;
import nativekit.ffi.NativeKitTypes.SurfaceFrameCallbackCallback;

/** Registration token for one retained NativeKit frame callback. */
class SurfaceFrameSubscription {
	final surface:Surface;
	final callback:SurfaceFrameCallbackCallback;
	var disposed:Bool = false;

	@:allow(Surface)
	private function new(surface:Surface, callback:SurfaceFrameCallbackCallback) {
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

	@:allow(Surface)
	function releasedAfterDetach():Void {
		if (disposed)
			return;
		disposed = true;
		callback.close();
	}

}
