package haxeon.ui.host;

/** Platform-neutral surface, viewport, scale, and frame-timing state. */
class UiHostFrameState {
	public var logicalWidth(default, null):Float;
	public var logicalHeight(default, null):Float;
	public var framebufferWidth(default, null):Int;
	public var framebufferHeight(default, null):Int;
	public var scale(default, null):Float = 1.0;
	public var zoom(default, null):Float = 1.0;
	public var layoutWidth(get, never):Float;
	public var layoutHeight(get, never):Float;
	public var renderScale(get, never):Float;
	function get_layoutWidth():Float return logicalWidth / zoom;
	function get_layoutHeight():Float return logicalHeight / zoom;
	function get_renderScale():Float return scale * zoom;
	public var surfaceAvailable(default, null):Bool = false;
	var previousTime:Float = -1.0;

	public function new(width:Int, height:Int) {
		logicalWidth = width;
		logicalHeight = height;
		framebufferWidth = width;
		framebufferHeight = height;
	}

	/** Dimension changes never imply that a native surface is available. */
	public function resize(width:Float, height:Float, framebufferWidth:Int,
			framebufferHeight:Int):Void {
		logicalWidth = width;
		logicalHeight = height;
		this.framebufferWidth = framebufferWidth;
		this.framebufferHeight = framebufferHeight;
	}

	public function setScale(value:Float):Void if (Math.isFinite(value) && value > 0.0) scale = value;
	public function setZoom(value:Float):Void if (Math.isFinite(value) && value > 0.0) zoom = value;

	public function setSurfaceAvailable(value:Bool):Void {
		if (surfaceAvailable != value) previousTime = -1.0;
		surfaceAvailable = value;
	}

	public function canRender():Bool {
		return surfaceAvailable && logicalWidth > 0.0 && logicalHeight > 0.0 &&
			framebufferWidth > 0 && framebufferHeight > 0;
	}

	public function nextDelta(timeSeconds:Float):Float {
		var delta = previousTime < 0.0 ? 0.0 :
			Math.max(0.0, Math.min(0.1, timeSeconds - previousTime));
		previousTime = timeSeconds;
		return delta;
	}
}
