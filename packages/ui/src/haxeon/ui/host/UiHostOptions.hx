package haxeon.ui.host;

import haxe.io.Bytes;
import haxeon.ui.FontCollection;

/** Settings shared by desktop and browser UI hosts. */
class UiHostOptions {
	public var title:String = "NativeKit UI";
	/** Stable application identifier passed to the desktop platform. */
	public var applicationId:Null<String> = null;
	public var width:Int = 1280;
	public var height:Int = 800;
	public var eventQueueCapacity:Int = 256;

	/** Additional browser fonts loaded before the application starts. */
	public var fonts:Null<Array<UiFontAsset>> = null;
	/** Called after a successful frame render. */
	public var onFrameRendered:Null<Void->Void> = null;
	/** Observes a managed host failure before it propagates to the runner. */
	public var onError:Null<haxe.Exception->Void> = null;

	public function new(?source:UiHostOptions) {
		if (source == null) return;
		title = source.title;
		applicationId = source.applicationId;
		width = source.width;
		height = source.height;
		eventQueueCapacity = source.eventQueueCapacity;
		fonts = source.fonts;
		onFrameRendered = source.onFrameRendered;
		onError = source.onError;
	}

	public function validate():Void {
		if (title == null || title.length == 0 || width <= 0 || height <= 0 || eventQueueCapacity <= 0)
			throw haxeon.platform.BindingError.invalidArgument("UiHostOptions", "UI host options are invalid");
		if (fonts != null)
			for (font in fonts)
				if (font == null || font.name == null || font.name.length == 0 || font.uri == null
					|| font.uri.length == 0)
					throw haxeon.platform.BindingError.invalidArgument("UiHostOptions", "UI font asset is invalid");
	}
}

/** Window, pacing, and deterministic-capture policy for the desktop UI host. */
class DesktopUiHostOptions extends UiHostOptions {
	public var customTitlebar:Bool = false;
	/** Where to put the window before it is first shown, such as where it was on the last run; null lets the system choose. */
	public var placement:Null<WindowPlacement> = null;
	/** Brings the window to the front once shown, as when it replaces a window the user was working in. */
	public var activate:Bool = false;
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
	public var captureReady:Null<Void->Bool> = null;
	/** True while application state changes without input events, such as live simulation. */
	public var continuousFrames:Null<Void->Bool> = null;
	public var eventHistoryLimit:Int = 100;
	public var icons:Null<ApplicationIconSet> = null;

	public function new(?source:UiHostOptions) super(source);

	/**
	 * Applies the host's standard command-line flags, so any app can be run for a number of frames, captured or driven by a
	 * script without code of its own, and returns the options: `--frames=N` (stop after N rendered frames, requesting
	 * redraws while idle), `--capture=DIR` (write diagnostics and, on X11, a window image to DIR),
	 * `--capture-seconds=S` (capture after S seconds instead) and
	 * `--input-script=PATH` (timed input, `ScriptedInput`). Other arguments are the app's and are left alone.
	 */
	public function withArguments(arguments:Array<String>):DesktopUiHostOptions {
		for (argument in arguments) {
			var separator = argument.indexOf("=");
			if (!StringTools.startsWith(argument, "--") || separator < 0)
				continue;
			var value = argument.substr(separator + 1);
			switch argument.substr(0, separator) {
				case "--frames":
					var frames = Std.parseInt(value);
					if (frames == null || frames < 0)
						throw 'Invalid --frames value "$value"';
					frameLimit = frames;
				case "--capture":
					captureDirectory = value;
				case "--capture-seconds":
					var seconds = Std.parseFloat(value);
					if (!Math.isFinite(seconds) || seconds < 0)
						throw 'Invalid --capture-seconds value "$value"';
					captureSeconds = seconds;
				case "--input-script":
					inputScriptPath = value;
				case _:
			}
		}
		return this;
	}

	override public function validate():Void {
		super.validate();
		if (minimumWidth < 0 || minimumHeight < 0 || targetFps <= 0.0 || frameLimit < 0 || captureSeconds < 0.0
			|| !Math.isFinite(captureSeconds) || eventHistoryLimit < 0)
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

/** An additional browser font fetched by URL. */
class UiFontAsset {
	public final name:String;
	public final uri:String;
	public final family:FontFamily;

	public function new(name:String, uri:String, family:FontFamily) {
		this.name = name;
		this.uri = uri;
		this.family = family;
	}
}

/** RGBA8 rows for a desktop window icon. Stride is measured in bytes. */
class WindowIcon {
	public final width:Int;
	public final height:Int;
	public final stride:Int;
	public final pixels:Bytes;

	public function new(width:Int, height:Int, stride:Int, pixels:Bytes) {
		if (width <= 0 || height <= 0 || pixels == null || width > 0x1fffffff || stride < width * 4
			|| height > Std.int(0x7fffffff / stride) || pixels.length != stride * height)
			throw "Window icon dimensions, stride, and byte count must agree";
		this.width = width;
		this.height = height;
		this.stride = stride;
		this.pixels = pixels;
	}
}

/** RGBA8 images at the sizes supplied by an application. */
class ApplicationIconSet {
	final images:Array<WindowIcon>;
	public final byteCount:Int;

	public function new(images:Array<WindowIcon>) {
		if (images == null || images.length == 0 || images.length > 16)
			throw "An application icon set requires 1 to 16 images";
		var total = 0;
		for (image in images) {
			if (image == null || image.pixels.length > 0x7fffffff - total)
				throw "Application icon set is too large";
			total += image.pixels.length;
		}
		this.images = images.copy();
		this.byteCount = total;
	}

	public function imageList():Array<WindowIcon> {
		return images.copy();
	}
}

/**
	Where a desktop window sits, so an application can put it back there on its next run: the outer bounds in logical
	screen pixels, and whether it is maximized. For a maximized window the bounds are the ones it restores to.
**/
class WindowPlacement {
	public final x:Int;
	public final y:Int;
	public final width:Int;
	public final height:Int;
	public final maximized:Bool;

	public function new(x:Int, y:Int, width:Int, height:Int, maximized:Bool) {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
		this.maximized = maximized;
	}
}
