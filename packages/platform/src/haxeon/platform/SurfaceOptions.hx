package haxeon.platform;

import haxeon.platform.Surface;
import nativekit.ffi.NativeKitTypes.GraphicsApi;
import nativekit.ffi.NativeKitTypes.SurfaceFlags;
import nativekit.ffi.NativeKitTypes.SurfaceOptions as NativeSurfaceOptions;

/** Graphics API, logical bounds, sharing, and flags for a window surface. */
class SurfaceOptions {
	public var width:Int;
	public var height:Int;
	public var x:Int = 0;
	public var y:Int = 0;
	public var flags:SurfaceFlags = SurfaceFlags.empty();
	public var api:GraphicsApi = cast 0;
	public var majorVersion:Int = 0;
	public var minorVersion:Int = 0;
	public var shareSurface:Null<Surface> = null;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

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
