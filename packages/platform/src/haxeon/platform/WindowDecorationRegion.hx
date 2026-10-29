package haxeon.platform;

import nativekit.ffi.NativeKitTypes.CursorShape;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegion as NativeWindowDecorationRegion;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;

/** A native window-chrome hit region, measured in logical client coordinates. */
class WindowDecorationRegion {
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

	public function nativeValue():NativeWindowDecorationRegion {
		var value = new NativeWindowDecorationRegion();
		value.set_x(x);
		value.set_y(y);
		value.set_width(width);
		value.set_height(height);
		value.set_kind(kind);
		value.set_cursor_shape(cursorShape);
		return value;
	}
}
