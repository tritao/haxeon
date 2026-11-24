package haxeon.gpu;

import haxeon.platform.SurfaceOptions as PlatformSurfaceOptions;
import nativekit.ffi.NativeKitGpu;
import nativekit.ffi.NativeKitTypes.GraphicsApi;
import nativekit.ffi.NativeKitTypes.SurfaceFlags;

/** Configures a platform surface for the GPU adapter's default backend. */
class SurfaceOptions {
	public static function forGpu(width:Int, height:Int, ?flags:SurfaceFlags):PlatformSurfaceOptions {
		if (width <= 0 || height <= 0)
			throw haxeon.platform.BindingError.invalidArgument("SurfaceOptions.forGpu",
				"Surface dimensions must be positive");
		var options = new PlatformSurfaceOptions(width, height);
		options.flags = (flags ?? SurfaceFlags.empty()) | SurfaceFlags.Depth | SurfaceFlags.Stencil
			| SurfaceFlags.FillWindow;
		options.api = NativeKitGpu.nkgpu_default_graphics_api();
		// The shader build compiles desktop OpenGL shaders to GLSL 4.1.
		if (options.api == GraphicsApi.Opengl) {
			options.flags = options.flags | SurfaceFlags.ForwardCompatible;
			options.majorVersion = 4;
			options.minorVersion = 1;
		}
		return options;
	}
}
