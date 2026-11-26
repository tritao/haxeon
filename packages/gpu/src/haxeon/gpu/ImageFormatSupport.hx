package haxeon.gpu;

import haxeon.gpu.Renderer;

import nativekit.ffi.NativeKitGpu;

/** Portable operations supported by one image format on a renderer. */
class ImageFormatSupport {
	/** Whether shaders can sample it. */
	public final sampled:Bool;

	/** Whether sampling can filter it linearly. */
	public final filter:Bool;

	/** Whether passes can draw into it. */
	public final renderTarget:Bool;

	/** Whether drawing into it can blend. */
	public final blend:Bool;

	/** Whether it can be multisampled. */
	public final multisample:Bool;

	/** Whether it can be a depth-stencil attachment. */
	public final depthStencil:Bool;

	/** Whether shaders can write it as a storage image. */
	public final storage:Bool;

	private function new(value:nkgpu_image_format_support) {
		sampled = value.get_sampled() != 0;
		filter = value.get_filter() != 0;
		renderTarget = value.get_render_target() != 0;
		blend = value.get_blend() != 0;
		multisample = value.get_multisample() != 0;
		depthStencil = value.get_depth_stencil() != 0;
		storage = value.get_storage() != 0;
	}

	@:allow(haxeon.gpu.Renderer)
	static function fromNative(value:nkgpu_image_format_support):ImageFormatSupport
		return new ImageFormatSupport(value);
}
