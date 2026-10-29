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
	public var flags:SurfaceFlags = cast 0;
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
		value.set_struct_size(NativeSurfaceOptions.size());
		value.set_width(width);
		value.set_height(height);
		value.set_x(x);
		value.set_y(y);
		value.set_flags(flags);
		value.set_api(api);
		value.set_major_version(majorVersion);
		value.set_minor_version(minorVersion);
		if (shareSurface != null) value.set_share_surface(shareSurface.nativeHandle());
		return value;
	}
}
