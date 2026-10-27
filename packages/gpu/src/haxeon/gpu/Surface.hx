package haxeon.gpu;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.Window;

import haxeon.gpu.SurfaceFrame;

import haxeon.gpu.Renderer;

import haxeon.gpu.GpuResult;
import nativekit.ffi.NativeKitGpu;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Owns a GPU-adapter surface associated with a NativeKit window. */
class Surface {
	final window:Window;
	final registration:haxeon.platform.DisposalRegistration;
	final renderers:Array<Renderer> = [];
	var value:SurfaceHandle;
	var disposed:Bool = false;

	private function new(window:Window, value:SurfaceHandle) {
		this.window = window;
		this.value = value;
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

	public function nativeHandle():SurfaceHandle {
		ensureLive();
		return value;
	}

	/** Acquires an immutable surface frame for explicit batch submission. */
	public function acquireFrame():haxeon.gpu.SurfaceFrame {
		ensureLive();
		var target = new SurfaceFrameTarget();
		target.set_struct_size(SurfaceFrameTarget.size());
		var acquired = NativeKit.nk_surface_acquire_frame(value, target);
		if (acquired.status != Result.Ok)
			throw new NativeKitError(acquired.status, "surface.acquireFrame", NativeKit.nk_last_error());
		return new haxeon.gpu.SurfaceFrame(this, acquired.out_frame, acquired.out_target);
	}

	public function createRenderer():Renderer {
		ensureLive();
		return Renderer.create(this);
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
		var snapshot = renderers.copy();
		for (index in 0...snapshot.length)
			snapshot[snapshot.length - 1 - index].dispose();
		GpuResult.check(NativeKitGpu.nkgpu_surface_destroy(value), "surface.dispose");
		disposed = true;
		registration.detach();
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(Renderer)
	function attachRenderer(renderer:Renderer):Void {
		ensureLive();
		renderers.push(renderer);
	}

	@:allow(Renderer)
	function rendererDisposed(renderer:Renderer):Void { renderers.remove(renderer); }

	@:allow(Renderer)
	function windowOwner():Window
		return window;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Surface.ensureLive", "GPU surface has been disposed");
	}
}
