package nativekit.ui.host;

import haxe.io.Bytes;

/** RGBA8 rows for a desktop window icon. Stride is measured in bytes. */
class WindowIcon {
	public final width:Int;
	public final height:Int;
	public final stride:Int;
	public final pixels:Bytes;

	public function new(width:Int, height:Int, stride:Int, pixels:Bytes) {
		if (width <= 0 || height <= 0 || pixels == null ||
			width > 0x1fffffff || stride < width * 4 ||
			height > Std.int(0x7fffffff / stride) || pixels.length != stride * height)
			throw "Window icon dimensions, stride, and byte count must agree";
		this.width = width;
		this.height = height;
		this.stride = stride;
		this.pixels = pixels;
	}
}
