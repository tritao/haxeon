package haxeon.ui;

import NativeKitUI;

/** Common lifetime implementation for typed UI resources. */
class NativeKitUIResource implements Disposable {
	var value:nkui_resource;
	var disposed:Bool;

	function new(value:nkui_resource) {
		this.value = value;
		disposed = false;
	}

	/** Releases this resource. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		var status = NativeKitUI.nkui_resource_destroy(value);
		disposed = true;
		UiResult.check(status, "resource.dispose");
	}

	/** Whether it was disposed, after which it may not be used. */
	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.ui.CanvasCommandBuffer)
	@:allow(haxeon.ui.Canvas)
	@:allow(haxeon.ui.DisplayList)
	@:allow(haxeon.ui.FontCollection)
	@:allow(haxeon.ui.GraphicsSurface)
	@:allow(ShowcaseCube)
	@:allow(haxeon.ui.TextLayout)
	@:allow(haxeon.ui.LayoutSession)
	private function nativeHandle():nkui_resource {
		if (disposed)
			throw "NativeKit UI resource has been disposed";
		return value;
	}
}
