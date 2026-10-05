package haxeon.ui.host;

import haxeon.ui.FontCollection;
import haxeon.platform.NativeKitEvents;
import nativekit.ffi.NativeKitTypes;

/** Live services, with the window and surface, available while constructing a hosted desktop or browser application. */
class DesktopUiHostContext extends UiHostContext {
	/** Borrowed window handle for application-owned native dialogs. */
	public final window:WindowHandle;
	/** Borrowed main graphics surface used to create compatible auxiliary renderers. */
	public final surface:SurfaceHandle;
	/** An application may defer closing while it asks to save a document. */
	@:allow(haxeon.ui.host.DesktopUiHost)
	@:allow(haxeon.ui.host.BrowserUiHost)
	private function new(fonts:FontCollection, events:NativeKitEvents, window:WindowHandle, surface:SurfaceHandle,
			close:Void->Void, scheduleFrame:Void->Void) {
		super(fonts, events, close, scheduleFrame);
		this.window = window;
		this.surface = surface;
	}
}
