package haxeon.gpu;

import haxeon.gpu.Renderer;

import nativekit.ffi.NativeKitGpu;

/** Portable resource and binding limits exposed by one renderer. */
class Limits {
	/** The widest or tallest 2D image, in pixels. */
	public final maxTextureSize:Int;

	/** The most layers an array image may have. */
	public final maxArrayLayers:Int;

	/** The most vertex attributes a pipeline may read. */
	public final maxVertexAttributes:Int;

	/** The most colour attachments a pass may have. */
	public final maxColorAttachments:Int;

	/** The most textures a stage may bind. */
	public final maxTextureBindings:Int;

	/** The most storage buffers a stage may bind. */
	public final maxStorageBufferBindings:Int;

	/** The most storage images a stage may bind. */
	public final maxStorageImageBindings:Int;

	/** The largest cube face, in pixels. */
	public final maxCubeSize:Int;

	private function new(value:nkgpu_limits) {
		maxTextureSize = value.get_max_texture_size();
		maxArrayLayers = value.get_max_array_layers();
		maxVertexAttributes = value.get_max_vertex_attributes();
		maxColorAttachments = value.get_max_color_attachments();
		maxTextureBindings = value.get_max_texture_bindings();
		maxStorageBufferBindings = value.get_max_storage_buffer_bindings();
		maxStorageImageBindings = value.get_max_storage_image_bindings();
		maxCubeSize = value.get_max_cube_size();
	}

	@:allow(haxeon.gpu.Renderer)
	static function fromNative(value:nkgpu_limits):Limits
		return new Limits(value);
}
