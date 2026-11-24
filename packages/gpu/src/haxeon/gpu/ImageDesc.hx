package haxeon.gpu;

import haxeon.gpu.Enums;
import haxeon.gpu.Image;

import haxeon.gpu.Enums.ImageFormat;
import haxeon.gpu.Enums.ImageType;
import haxeon.gpu.Enums.ImageUsage;
import nativekit.ffi.NativeKitGpu;

/** Portable descriptor for a NativeKit GPU image. */
class ImageDesc {
	public var width:Int;
	public var height:Int;
	public var format:ImageFormat;
	public var usage:ImageUsage;
	public var mipCount:Int;
	public var sampleCount:Int;
	public var layerCount:Int;
	public var rowPitch:Int;
	public var dynamicUpdate:Bool;
	public var type:ImageType;

	public function new(width:Int, height:Int, format:ImageFormat = ImageFormat.Rgba8,
			usage:ImageUsage = ImageUsage.Sampled) {
		this.width = width;
		this.height = height;
		this.format = format;
		this.usage = usage;
		mipCount = 1;
		sampleCount = 1;
		layerCount = 1;
		rowPitch = 0;
		dynamicUpdate = false;
		type = ImageType.Auto;
	}

	@:allow(haxeon.gpu.Image)
	function nativeValue():nkgpu_image_desc {
		var value = new nkgpu_image_desc();
		value.struct_size = nkgpu_image_desc.byteSize();
		value.width = width;
		value.height = height;
		value.format = format;
		value.usage = usage;
		value.mip_count = mipCount;
		value.sample_count = sampleCount;
		value.layer_count = layerCount;
		value.data_size = 0;
		value.row_pitch = rowPitch;
		value.dynamic_update = dynamicUpdate ? 1 : 0;
		value.type = type;
		return value;
	}
}
