package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** Managed options; native ABI storage is created only at the interop boundary. */
class SurfaceConfig {
	public var width:Int;
	public var height:Int;
	public var x:Int = 0;
	public var y:Int = 0;
	public var flags:SurfaceFlags = cast 0;
	public var api:GraphicsApi = cast 0;
	public var majorVersion:Int = 0;
	public var minorVersion:Int = 0;
	public var shareSurface:Null<NativeKitSurface> = null;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	public function nativeValue():SurfaceOptions {
		var value = new SurfaceOptions();
		value.set_struct_size(SurfaceOptions.size());
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
