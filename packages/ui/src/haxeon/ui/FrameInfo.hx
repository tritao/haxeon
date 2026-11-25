package haxeon.ui;

import NativeKitUI;

/** Per-frame logical and physical surface dimensions. */
class FrameInfo {
	var nativeFrame:nkui_frame_info;

	/** The surface's width, in logical pixels. */
	public var logicalWidth:Float;

	/** The surface's height, in logical pixels. */
	public var logicalHeight:Float;

	/** Its width, in device pixels. */
	public var framebufferWidth:Int;

	/** Its height, in device pixels. */
	public var framebufferHeight:Int;

	/** Device pixels per logical pixel. */
	public var pixelScale:Float;

	/** A frame of the given sizes. */
	public function new(logicalWidth:Float, logicalHeight:Float, framebufferWidth:Int, framebufferHeight:Int,
			pixelScale:Float) {
		if (logicalWidth <= 0.0 || logicalHeight <= 0.0 || framebufferWidth <= 0 || framebufferHeight <= 0
			|| pixelScale <= 0.0)
			throw "Frame dimensions and pixel scale must be positive";
		this.logicalWidth = logicalWidth;
		this.logicalHeight = logicalHeight;
		this.framebufferWidth = framebufferWidth;
		this.framebufferHeight = framebufferHeight;
		this.pixelScale = pixelScale;
		nativeFrame = new nkui_frame_info();
	}

	/** Updates this reusable frame description without allocating a new ABI struct. */
	public function set(logicalWidth:Float, logicalHeight:Float, framebufferWidth:Int,
			framebufferHeight:Int, pixelScale:Float):FrameInfo {
		if (logicalWidth <= 0.0 || logicalHeight <= 0.0 || framebufferWidth <= 0 || framebufferHeight <= 0
			|| pixelScale <= 0.0)
			throw "Frame dimensions and pixel scale must be positive";
		this.logicalWidth = logicalWidth;
		this.logicalHeight = logicalHeight;
		this.framebufferWidth = framebufferWidth;
		this.framebufferHeight = framebufferHeight;
		this.pixelScale = pixelScale;
		return this;
	}

	@:allow(haxeon.ui.Renderer)
	@:allow(haxeon.ui.LayoutSession)
	private function nativeValue():nkui_frame_info {
		nativeFrame.set_logical_width(logicalWidth);
		nativeFrame.set_logical_height(logicalHeight);
		nativeFrame.set_framebuffer_width(framebufferWidth);
		nativeFrame.set_framebuffer_height(framebufferHeight);
		nativeFrame.set_pixel_scale(pixelScale);
		return nativeFrame;
	}
}
