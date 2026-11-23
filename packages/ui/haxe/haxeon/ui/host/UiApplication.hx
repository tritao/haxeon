package haxeon.ui.host;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;

/** Platform-neutral application consumed by a NativeKit UI host. */
interface UiApplication extends Disposable {
	public function context():UiContext;
	public function submit(frame:LayoutFrame):RenderNode;
}
