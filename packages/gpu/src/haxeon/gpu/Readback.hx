package haxeon.gpu;

import haxeon.platform.BindingError;

import haxeon.gpu.Buffer;
import haxeon.gpu.Enums;
import haxeon.gpu.Image;

import haxeon.gpu.Renderer;

import haxeon.gpu.GpuResult;

import haxe.io.Bytes;
import haxeon.gpu.Enums.ReadbackState;
import nativekit.ffi.NativeKitGpu;

/** Owns one asynchronous image or buffer readback request. */
class Readback implements Disposable {
	final renderer:Renderer;
	final registration:haxeon.platform.DisposalRegistration;
	final value:nkgpu_readback;
	var disposed:Bool = false;

	private function new(renderer:Renderer, value:nkgpu_readback) {
		this.renderer = renderer;
		this.value = value;
		registration = renderer.registerResource(rendererClosed);
	}

	/** Starts a tightly packed readback of an image rectangle. */
	public static function begin(image:Image, x:Int, y:Int, width:Int, height:Int,
			mipLevel:Int = 0, layer:Int = 0):Readback {
		if (image == null || width <= 0 || height <= 0 || x < 0 || y < 0 || mipLevel < 0 || layer < 0)
			throw BindingError.invalidArgument("Readback.begin", "GPU readback region is invalid");
		var renderer = image.rendererOwner();
		renderer.ensureResourceOperation();
		var desc = new nkgpu_image_readback_desc();
		desc.struct_size = nkgpu_image_readback_desc.byteSize();
		desc.image = image.nativeHandle();
		desc.mip_level = mipLevel;
		desc.layer = layer;
		desc.x = x;
		desc.y = y;
		desc.width = width;
		desc.height = height;
		var made = NativeKitGpu.nkgpu_readback_begin_image(renderer.nativeHandle(), desc);
		GpuResult.check(made.status, "readback.begin");
		return new Readback(renderer, made.out_readback);
	}

	/** Starts a tightly packed readback of an arbitrary buffer range. */
	public static function beginBuffer(buffer:Buffer, offset:Int, size:Int):Readback {
		if (buffer == null || offset < 0 || size <= 0)
			throw BindingError.invalidArgument("Readback.beginBuffer", "GPU buffer readback range is invalid");
		var renderer = buffer.rendererOwner();
		renderer.ensureResourceOperation();
		var desc = new nkgpu_buffer_readback_desc();
		desc.struct_size = nkgpu_buffer_readback_desc.byteSize();
		desc.buffer = buffer.nativeHandle();
		desc.offset = offset;
		desc.size = size;
		var made = NativeKitGpu.nkgpu_readback_begin_buffer(renderer.nativeHandle(), desc);
		GpuResult.check(made.status, "readback.beginBuffer");
		return new Readback(renderer, made.out_readback);
	}

	/** Whether the copy has finished, and the shape of its data. */
	public function query():ReadbackInfo {
		ensureLive();
		renderer.ensureResourceOperation();
		var result = NativeKitGpu.nkgpu_readback_query(renderer.nativeHandle(), value);
		GpuResult.check(result.status, "readback.query");
		return ReadbackInfo.fromNative(result.out_info);
	}

	/** Copies the finished data into `data` and returns how many bytes it wrote. */
	public function read(data:Bytes):Int {
		ensureLive();
		if (data == null || data.length == 0)
			throw BindingError.invalidArgument("Readback.read", "GPU readback destination must not be empty");
		renderer.ensureResourceOperation();
		var result = NativeKitGpu.nkgpu_readback_read(renderer.nativeHandle(), value, data, data.length);
		GpuResult.check(result.status, "readback.read");
		return result.out_size;
	}

	public function dispose():Void {
		if (disposed)
			return;
		renderer.ensureResourceOperation();
		GpuResult.check(NativeKitGpu.nkgpu_readback_destroy(renderer.nativeHandle(), value), "readback.dispose");
		disposed = true;
		registration.detach();
	}

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.gpu.Renderer)
	function rendererClosed():Void {
		disposed = true;
		registration.detach();
	}

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Readback.ensureLive", "GPU readback has been disposed");
		renderer.ensureLive();
	}
}

/** Snapshot of an asynchronous readback's state and packed result layout. */
class ReadbackInfo {
	/** Whether the data is pending, ready or failed. */
	public final state:ReadbackState;

	/** How many bytes it holds. */
	public final size:Int;

	/** The bytes per row, for an image. */
	public final rowPitch:Int;

	/** The image's width, in pixels. */
	public final width:Int;

	/** The image's height, in pixels. */
	public final height:Int;

	private function new(state:ReadbackState, size:Int, rowPitch:Int, width:Int, height:Int) {
		this.state = state;
		this.size = size;
		this.rowPitch = rowPitch;
		this.width = width;
		this.height = height;
	}

	@:allow(haxeon.gpu.Readback)
	static function fromNative(value:nkgpu_readback_info):ReadbackInfo
		return new ReadbackInfo(value.state, value.size, value.row_pitch,
			value.width, value.height);
}
