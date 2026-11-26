package haxeon.ui.host;

import haxeon.platform.SurfaceFrame;
import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;

/** Platform-neutral application consumed by a NativeKit UI host. */
interface UiApplication extends Disposable {
	/** The context the application builds its views in, which the host renders and delivers input to. */
	public function context():UiContext;

	/** Builds the frame's view into `frame` (its viewport and time step) and returns what to render. */
	public function submit(frame:LayoutFrame):RenderNode;
}

/** A UI application that can submit its own work into the host's frame. */
interface UiFrameApplication extends UiApplication {
	/** Returns false to use the regular view submission for this frame. */
	function submitFrame(frame:SurfaceFrame, info:FrameInfo, timeSeconds:Float):Bool;
}

/** Optional diagnostic state exposed by applications that support capture runs. */
interface UiDiagnosticsProvider {
	/** The application's state as plain data, written beside each captured frame as JSON for a test to compare. */
	public function diagnosticState():Dynamic;
}
