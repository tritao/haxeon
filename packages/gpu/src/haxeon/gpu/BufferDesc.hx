package haxeon.gpu;

import haxeon.gpu.Buffer;
import haxeon.gpu.Enums;

import haxeon.gpu.Enums.BufferUsage;
import nativekit.ffi.NativeKitGpu;

/** Portable descriptor for a NativeKit GPU buffer. */
class BufferDesc {
	public var size:Int;
	public var usage:BufferUsage;
	public var dynamicUpdate:Bool;
	public var stream:Bool;

	public function new(size:Int, usage:BufferUsage) {
		this.size = size;
		this.usage = usage;
		dynamicUpdate = false;
		stream = false;
	}

	@:allow(haxeon.gpu.Buffer)
	function nativeValue():nkgpu_buffer_desc {
		var value = new nkgpu_buffer_desc();
		value.struct_size = nkgpu_buffer_desc.byteSize();
		value.size = size;
		value.usage = usage;
		value.data_size = 0;
		value.dynamic_update = dynamicUpdate ? 1 : 0;
		value.stream = stream ? 1 : 0;
		return value;
	}
}
