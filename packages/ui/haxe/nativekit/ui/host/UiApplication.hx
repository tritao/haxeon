package nativekit.ui.host;

import LayoutFrame;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiContext;

/** Platform-neutral application consumed by a NativeKit UI host. */
interface UiApplication {
	public function context():UiContext;
	public function submit(frame:LayoutFrame):RenderNode;
	public function dispose():Void;
}
