package haxeon.ui.core;

import nativekit.ffi.NativeKitTypes.TouchTool;

/** Platform touch details preserved on normalized pointer events. */
class UiTouchData {
	public final tool:TouchTool;
	public final pressure:Float;
	public final tiltX:Float;
	public final tiltY:Float;

	public function new(tool:TouchTool, pressure:Float, tiltX:Float, tiltY:Float) {
		this.tool = tool;
		this.pressure = pressure;
		this.tiltX = tiltX;
		this.tiltY = tiltY;
	}
}
