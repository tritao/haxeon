package haxeon.ui;

import NativeKitUI;

/** Per-submission viewport and timing for a LayoutSession. */
class LayoutFrame {
	var nativeFrame:nkui_layout_frame_input;

	/** The viewport's width, in logical pixels. */
	public var width:Float;

	/** The viewport's height, in logical pixels. */
	public var height:Float;

	/** The time since the previous frame, for animations. */
	public var deltaSeconds:Float;

	/** A frame of a `width` by `height` viewport. */
	public function new(width:Float, height:Float) {
		if (width <= 0.0 || height <= 0.0)
			throw "Layout frame dimensions must be positive";
		this.width = width;
		this.height = height;
		deltaSeconds = 0.0;
		nativeFrame = new nkui_layout_frame_input();
	}

	/** Sets the viewport's size, and returns the frame. */
	public function setViewport(width:Float, height:Float):LayoutFrame {
		if (width <= 0.0 || height <= 0.0)
			throw "Layout frame dimensions must be positive";
		this.width = width;
		this.height = height;
		return this;
	}

	@:allow(haxeon.ui.LayoutSession)
	private function nativeValue():nkui_layout_frame_input {
		nativeFrame.set_width(width);
		nativeFrame.set_height(height);
		nativeFrame.set_delta_seconds(deltaSeconds);
		return nativeFrame;
	}
}
