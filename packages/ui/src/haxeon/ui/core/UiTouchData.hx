package haxeon.ui.core;

import nativekit.ffi.NativeKitTypes.TouchTool;

/** Platform touch details preserved on normalized pointer events. */
class UiTouchData {
	/** What touched: a finger, a pen or an eraser. */
	public final tool:TouchTool;

	/** How hard, normalized from 0 to 1; the platform's default when the device does not report it. */
	public final pressure:Float;

	/** A pen's tilt around the x axis, in the platform's normalized units; 0 when not reported. */
	public final tiltX:Float;

	/** A pen's tilt around the y axis, in the platform's normalized units; 0 when not reported. */
	public final tiltY:Float;

	/** Touch details as the platform reports them. */
	public function new(tool:TouchTool, pressure:Float, tiltX:Float, tiltY:Float) {
		this.tool = tool;
		this.pressure = pressure;
		this.tiltX = tiltX;
		this.tiltY = tiltY;
	}
}
