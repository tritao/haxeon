package haxeon.platform;

import nativekit.ffi.NativeKitTypes.NativeCursorShape;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegion as NativeWindowDecorationRegion;
import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;

/** A native window-chrome hit region, measured in logical client coordinates. */
class WindowDecorationRegion {
	/** Its left edge. */
	public var x:Float;

	/** Its top edge. */
	public var y:Float;

	/** Its width. */
	public var width:Float;

	/** Its height. */
	public var height:Float;

	/** What it does: drag the window, or act as a caption button. */
	public var kind:WindowDecorationRegionKind;
	/** A standard cursor for this region, or null for the native default its kind implies. */
	public var cursorShape:Null<NativeCursorShape> = null;

	/** A region of `kind`. */
	public function new(x:Float, y:Float, width:Float, height:Float, kind:WindowDecorationRegionKind) {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
		this.kind = kind;
	}

	/** The generated ABI record for it. */
	public function nativeValue():NativeWindowDecorationRegion {
		var value = new NativeWindowDecorationRegion();
		value.set_x(x);
		value.set_y(y);
		value.set_width(width);
		value.set_height(height);
		value.set_kind(kind);
		if (cursorShape != null)
			value.set_cursor_shape(cursorShape);
		return value;
	}
}
