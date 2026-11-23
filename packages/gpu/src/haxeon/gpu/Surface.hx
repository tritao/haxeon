package haxeon.gpu;

import haxeon.platform.BindingError;
import haxeon.platform.Surface as PlatformSurface;
import haxeon.platform.SurfaceFrameSubscription;
import haxeon.platform.SurfaceFrameTiming;
import haxeon.platform.Window;

import haxeon.gpu.FrameTick;
import haxeon.platform.SurfaceFrame;

import haxeon.gpu.Renderer;

import haxeon.gpu.GpuResult;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitGpu;
import nativekit.ffi.NativeKitTypes;

/** Owns a GPU-adapter surface associated with a NativeKit window. */
class Surface implements Disposable {
	final window:Window;
	final frameSource:PlatformSurface;
	final registration:haxeon.platform.DisposalRegistration;
	var value:SurfaceHandle;
	var disposed:Bool = false;

	private function new(window:Window, value:SurfaceHandle) {
		this.window = window;
		this.value = value;
		frameSource = PlatformSurface.borrowNativeHandle(value);
		registration = window.registerDependent(function() {
			dispose();
		});
	}

	public static function create(window:Window, width:Int, height:Int):Surface {
		if (width <= 0 || height <= 0)
			throw BindingError.invalidArgument("Surface.create", "GPU surface dimensions must be positive");
		var made = NativeKitGpu.nkgpu_surface_create(window.nativeHandle(), width, height);
		GpuResult.check(made.status, "surface.create");
		return new Surface(window, made.out_surface);
	}

	public static function createForApi(window:Window, api:GraphicsApi, width:Int, height:Int):Surface {
		if (width <= 0 || height <= 0)
			throw BindingError.invalidArgument("Surface.createForApi", "GPU surface dimensions must be positive");
		var made = NativeKitGpu.nkgpu_surface_create_for_api(window.nativeHandle(), api, width, height);
		GpuResult.check(made.status, "surface.createForApi");
		return new Surface(window, made.out_surface);
	}

	/** Whether a platform event came from this surface. */
	public function ownsEventSource(source:Handle):Bool
		return !disposed && frameSource.ownsEventSource(source);

	public function nativeHandle():SurfaceHandle {
		ensureLive();
		return value;
	}

	/**
	 * Replaces the surface's frame callback. The callback runs on the platform
	 * thread with the framebuffer current. The surface detaches it on disposal.
	 */
	public function onFrame(handler:FrameTick->Void):SurfaceFrameSubscription {
		ensureLive();
		if (handler == null)
			throw BindingError.invalidArgument("Surface.onFrame", "GPU frame handler must not be null");
		return frameSource.onFrame(function(width, height)
			handler(new FrameTick(Sys.monotonicTime(), width, height)));
	}

	/** Captures optional presentation feedback for the current frame callback. */
	public function captureFrameTiming(?callbackSeconds:Float):SurfaceFrameTiming {
		ensureLive();
		return frameSource.captureFrameTiming(callbackSeconds);
	}

	/** Selects continuous or on-demand callbacks for this surface. */
	public function setFrameMode(mode:SurfaceFrameMode):Void {
		ensureLive();
		frameSource.setFrameMode(mode);
	}

	/** Queues a redraw, including when the surface is in on-demand mode. */
	public function requestFrame():Void {
		ensureLive();
		frameSource.requestFrame();
	}

	/** Acquires the platform surface's frame. */
	public function acquireFrame():SurfaceFrame
		return frameSource.acquireFrame();

	public function createRenderer():Renderer {
		ensureLive();
		return Renderer.create(frameSource);
	}

	/** Sets the surface's position and size in window-local logical pixels. */
	public function setBounds(x:Int, y:Int, width:Int, height:Int):Void {
		ensureLive();
		if (width <= 0 || height <= 0)
			throw BindingError.invalidArgument("Surface.setBounds", "GPU surface dimensions must be positive");
		NativeKit.nk_surface_set_bounds_checked(value, x, y, width, height);
	}

	public function resize(width:Int, height:Int):Void {
		ensureLive();
		if (width <= 0 || height <= 0)
			throw BindingError.invalidArgument("Surface.resize", "GPU surface dimensions must be positive");
		GpuResult.check(NativeKitGpu.nkgpu_surface_resize(value, width, height), "surface.resize");
	}

	public function dispose():Void {
		if (disposed)
			return;
		frameSource.clearFrameCallback();
		frameSource.releaseDependents();
		GpuResult.check(NativeKitGpu.nkgpu_surface_destroy(value), "surface.dispose");
		frameSource.releaseBorrowed();
		disposed = true;
		registration.detach();
	}

	public function isDisposed():Bool
		return disposed;


	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Surface.ensureLive", "GPU surface has been disposed");
	}
}
