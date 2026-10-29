package haxeon.ui.host;

/** Window, pacing, and deterministic-capture policy for DesktopUiHost. */
class DesktopUiHostOptions extends UiHostOptions {
	/** Stable application identity, including Windows taskbar grouping. */
	public var applicationId:Null<String> = null;
	public var customTitlebar:Bool = false;
	/** Minimum application layout size, scaled by application zoom for native limits.
	 * Zero leaves an axis unconstrained. */
	public var minimumWidth:Int = 0;
	public var minimumHeight:Int = 0;
	public var inputScriptPath:Null<String> = null;
	public var targetFps:Float = 60.0;
	public var captureDirectory:Null<String> = null;
	/** Append-only JSONL trace of native events and host failures. */
	public var recordPath:Null<String> = null;
	public var recordMetadata:Dynamic = null;
	public var frameLimit:Int = 0;
	/** Capture after this wall-clock interval while preserving normal frame scheduling. */
	public var captureSeconds:Float = 0.0;
	/**
	 * Holds capture until the application says its content is loaded. Frames rendered while this
	 * returns false do not count toward `frameLimit` or start the `captureSeconds` timer, so a capture of
	 * an application that opens its document in the background shows the document, not its loading state.
	 */
	/** Called after a successful frame render, before capture bookkeeping. */
	public var onFrameRendered:Null<Void->Void> = null;
	public var captureReady:Null<Void->Bool> = null;
	/** True while application state changes without input events, such as live simulation. */
	public var continuousFrames:Null<Void->Bool> = null;
	public var eventHistoryLimit:Int = 100;
	public var icons:Null<ApplicationIconSet> = null;

	public function new() super();

	public function validate():Void {
		if (title == null || title.length == 0 || width <= 0 || height <= 0 ||
			minimumWidth < 0 || minimumHeight < 0 ||
			eventQueueCapacity <= 0 || targetFps <= 0.0 || frameLimit < 0 ||
			captureSeconds < 0.0 || !Math.isFinite(captureSeconds) ||
			eventHistoryLimit < 0)
			throw "Desktop UI host options are invalid";
		if (captureDirectory != null && captureDirectory.length == 0)
			throw "Desktop UI capture directory cannot be empty";
		if (recordPath != null && recordPath.length == 0)
			throw "Desktop UI recording path cannot be empty";
		if (captureDirectory != null && frameLimit == 0 && captureSeconds == 0.0)
			frameLimit = 3;
		if (captureSeconds > 0.0 && (captureDirectory == null || frameLimit > 0))
			throw "Timed desktop captures require a directory and no frame limit";
	}
}
