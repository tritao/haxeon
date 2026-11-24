package haxeon.ui.host;

import haxeon.platform.SurfaceFrame;
import haxeon.ui.FrameInfo;

/** A UI application that can submit its own work into the host's frame. */
interface UiFrameApplication extends UiApplication {
	/** Returns false to use the regular view submission for this frame. */
	function submitFrame(frame:SurfaceFrame, info:FrameInfo, timeSeconds:Float):Bool;
}
