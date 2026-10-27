package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** A native window-chrome hit region, measured in logical client coordinates. */
class DecorationRegion {
	public var x:Float;
	public var y:Float;
	public var width:Float;
	public var height:Float;
	public var kind:WindowDecorationRegionKind;
	public var cursorShape:CursorShape = cast 0;

	public function new(x:Float, y:Float, width:Float, height:Float, kind:WindowDecorationRegionKind) {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
		this.kind = kind;
	}

	public function nativeValue():WindowDecorationRegion {
		var value = new WindowDecorationRegion();
		value.set_x(x);
		value.set_y(y);
		value.set_width(width);
		value.set_height(height);
		value.set_kind(kind);
		value.set_cursor_shape(cursorShape);
		return value;
	}
}
