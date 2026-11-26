package haxeon.gpu;

import haxeon.gpu.Enums;
import haxeon.gpu.Image;

import haxeon.gpu.Enums.ImageFormat;
import haxeon.gpu.Enums.ImageType;
import haxeon.gpu.Enums.ImageUsage;
import nativekit.ffi.NativeKitGpu;

/** Portable descriptor for a NativeKit GPU image. */
class ImageDesc {
	/** Its width, in pixels. */
	public var width:Int;

	/** Its height, in pixels. */
	public var height:Int;

	/** Its pixel format. */
	public var format:ImageFormat;

	/** What it is used for: sampling, rendering, storage or transfers. */
	public var usage:ImageUsage;

	/** How many mip levels it has. */
	public var mipCount:Int;

	/** Its multisample count; one for none. */
	public var sampleCount:Int;

	/** How many layers it has; six per cube for cube images. */
	public var layerCount:Int;

	/** The bytes per row of its initial data, or zero for tightly packed rows. */
	public var rowPitch:Int;

	/** Whether it is updated after creation. */
	public var dynamicUpdate:Bool;

	/** Its shape; Auto picks 2D, or a 2D array with more than one layer. */
	public var type:ImageType;

	/** A one-level, single-sample 2D image. */
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
