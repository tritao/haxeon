package haxeon.platform;

import haxeon.platform.Surface;
import nativekit.ffi.NativeKitTypes.GraphicsApi;
import nativekit.ffi.NativeKitTypes.SurfaceFlags;
import nativekit.ffi.NativeKitTypes.SurfaceOptions as NativeSurfaceOptions;

/** Graphics API, logical bounds, sharing, and flags for a window surface. */
class SurfaceOptions {
	/** Its width, in logical pixels. */
	public var width:Int;

	/** Its height, in logical pixels. */
	public var height:Int;

	/** Its left edge within the window. */
	public var x:Int = 0;

	/** Its top edge within the window. */
	public var y:Int = 0;

	/** Its buffers and behaviour, such as depth or filling the window. */
	public var flags:SurfaceFlags = SurfaceFlags.empty();

	/** The graphics API, or zero for the default. */
	public var api:GraphicsApi = cast 0;

	/** The API's major version, for OpenGL. */
	public var majorVersion:Int = 0;

	/** The API's minor version. */
	public var minorVersion:Int = 0;

	/** A surface whose graphics resources it shares, or null. */
	public var shareSurface:Null<Surface> = null;

	/** Options for a `width` by `height` surface. */
	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	/** The generated ABI record for these options, for the `Native` interop entry points. */
	public function nativeValue():NativeSurfaceOptions {
		var value = new NativeSurfaceOptions();
		value.struct_size = NativeSurfaceOptions.byteSize();
		value.width = width;
		value.height = height;
		value.x = x;
		value.y = y;
		value.flags = flags;
		value.api = api;
		value.major_version = majorVersion;
		value.minor_version = minorVersion;
		if (shareSurface != null) value.share_surface = shareSurface.nativeHandle();
		return value;
	}
}
