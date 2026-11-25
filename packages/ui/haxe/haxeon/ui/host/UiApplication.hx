package haxeon.ui.host;

import haxeon.platform.SurfaceFrame;
import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;

/** Platform-neutral application consumed by a NativeKit UI host. */
interface UiApplication extends Disposable {
	public function context():UiContext;
	public function submit(frame:LayoutFrame):RenderNode;
}

/** A UI application that can submit its own work into the host's frame. */
interface UiFrameApplication extends UiApplication {
	/** Returns false to use the regular view submission for this frame. */
	function submitFrame(frame:SurfaceFrame, info:FrameInfo, timeSeconds:Float):Bool;
}

/** Optional diagnostic state exposed by applications that support capture runs. */
interface UiDiagnosticsProvider {
	public function diagnosticState():Dynamic;
}
