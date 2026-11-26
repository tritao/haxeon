package haxeon.gpu;

import haxeon.gpu.Renderer;

import nativekit.ffi.NativeKitGpu;

/** Optional GPU capabilities exposed by one renderer. */
class Features {
	/** How many colour attachments a pass may have. */
	public final mrtCount:Int;

	/** The highest multisample count. */
	public final maxSamples:Int;

	/** Whether shaders can use storage buffers. */
	public final storageBuffer:Bool;

	/** Whether shaders can use storage images. */
	public final storageImage:Bool;

	/** Whether compute passes are available. */
	public final compute:Bool;

	/** Whether instanced draws are available. */
	public final instancing:Bool;

	/** Whether buffers can be copied on the GPU. */
	public final bufferCopy:Bool;

	/** Whether images can be copied on the GPU. */
	public final imageCopy:Bool;

	/** Whether images can be read back to the CPU. */
	public final imageReadback:Bool;

	/** Whether buffers can be read back to the CPU. */
	public final bufferReadback:Bool;

	/** Whether GPU timestamps can be measured. */
	public final timestamps:Bool;

	private function new(value:nkgpu_features) {
		mrtCount = value.get_mrt_count();
		maxSamples = value.get_max_samples();
		storageBuffer = value.get_storage_buffer() != 0;
		storageImage = value.get_storage_image() != 0;
		compute = value.get_compute() != 0;
		instancing = value.get_instancing() != 0;
		bufferCopy = value.get_buffer_copy() != 0;
		imageCopy = value.get_image_copy() != 0;
		imageReadback = value.get_image_readback() != 0;
		bufferReadback = value.get_buffer_readback() != 0;
		timestamps = value.get_timestamps() != 0;
	}

	@:allow(haxeon.gpu.Renderer)
	static function fromNative(value:nkgpu_features):Features
		return new Features(value);
}
