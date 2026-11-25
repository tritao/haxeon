import haxe.CallStack;
import haxeon.platform.BindingError;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.event.EventSubscription;
import haxeon.ui.FontCollection;
import haxeon.ui.FrameInfo;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.UiApplication;
import haxeon.ui.host.UiHost;
import haxeon.ui.host.UiHostContext;
import haxeon.ui.host.UiHostOptions;
import nativekit.ffi.NativeKitTypes;

private enum abstract ShowcaseBenchmark(Int) {
	var None = -1;
	var Full = 0;
	var Static = 1;
	var TextHeavy = 2;
	var Editing = 3;
}

private typedef ShowcaseOptions = {
	final width:Int;
	final height:Int;
	final graphics:Bool;
	final visualCase:Int;
	final benchmark:ShowcaseBenchmark;
	final lightTheme:Bool;
}

/** The UI Explorer and Graphics Lab share a window, fonts, and frame transaction. */
class ShowcaseWeb implements UiFrameApplication {
	static var configuration:Null<ShowcaseOptions>;
	static var active:Null<ShowcaseWeb>;

	final host:DesktopUiHostContext;
	final config:ShowcaseOptions;
	final explorer:UiExplorer;
	final input:EventSubscription;
	var graphics:Null<Showcase>;
	var renderCount = 0;
	var startedAt:Null<Float>;

	public static function configure(width:Int, height:Int, mode:Int, visualCase:Int, benchmark:Int, light:Int):Void {
		if (width <= 0 || height <= 0 || mode < 0 || mode > 1 || visualCase < -1 || visualCase > 34
			|| benchmark < -1 || benchmark > 3 || light < 0 || light > 1 || active != null)
			throw BindingError.invalidArgument("ShowcaseWeb.configure", "Invalid showcase configuration");
		configuration = {
			width: width, height: height, graphics: mode == 1 || benchmark >= 0,
			visualCase: visualCase, benchmark: cast benchmark, lightTheme: light == 1
		};
	}

	public static function main():Void {
		var config = configuration ?? {
			width:1200, height:800, graphics:false, visualCase:-1, benchmark:None, lightTheme:true
		};
		var options = new UiHostOptions();
		options.title = "Haxeon UI Explorer";
		options.width = config.width;
		options.height = config.height;
		options.eventQueueCapacity = 64;
		options.fonts = [
			new UiFontAsset("IBMPlexSansArabic-Regular", "assets/IBMPlexSansArabic-Regular.ttf", FontFamily.Default),
			new UiFontAsset("IBMPlexSansHebrew-Regular", "assets/IBMPlexSansHebrew-Regular.ttf", FontFamily.Default),
			new UiFontAsset("IBMPlexSansJP-Regular", "assets/IBMPlexSansJP-Regular.ttf", FontFamily.Default),
			new UiFontAsset("NotoEmoji-Regular", "assets/NotoEmoji-Regular.ttf", FontFamily.Emoji)
		];
		options.onError = reportException;
		try {
			UiHost.run(context -> new ShowcaseWeb(cast context, config), options);
		} catch (error:haxe.Exception) {
			reportException(error);
			throw error;
		}
	}

	static function reportException(error:haxe.Exception):Void {
		NativeKitUIShowcase.nkui_showcase_diagnostic_report(0, error.message,
			CallStack.toString(error.stack), error.toString());
	}

	function new(host:DesktopUiHostContext, config:ShowcaseOptions) {
		this.host = host;
		this.config = config;
		explorer = new UiExplorer(host.fonts, "WEBGL2 · WASM", openGraphics, false, null, null, null, false);
		var opened = false;
		defer if (!opened) dispose();
		// A visual case sets its own theme.
		if (config.visualCase < 0) explorer.setLightTheme(config.lightTheme);
		// The page's start page, as `--page=<id>` (web_shell.html passes its `page` query).
		for (argument in Sys.args())
			if (StringTools.startsWith(argument, "--page=") && !explorer.openPage(argument.substr(7)))
				throw BindingError.invalidArgument("ShowcaseWeb", 'The UI Explorer has no page ${argument.substr(7)}');
		if (config.visualCase >= 0 && !explorer.setVisualCase(config.visualCase))
			throw BindingError.invalidArgument("ShowcaseWeb", "UI Explorer rejected the visual case");
		if (config.graphics) openGraphics();
		input = host.events.listen(function(event) {
			var lab = graphics;
			switch event {
				case PointerMove(source, x, y) if (lab != null && matches(source)):
					lab.updatePointer(x, y);
					host.requestFrame();
				case PointerButton(source, _, action, _, x, y) if (lab != null && matches(source)):
					lab.pointerButton(x, y, action == InputAction.Press);
					host.requestFrame();
				// A page has no window to close, so Escape only leaves the graphics lab opened from the explorer.
				case Key(source, Key.Escape, _, InputAction.Press,
					_) if (lab != null && !config.graphics && matches(source)):
					graphics = null;
					lab.dispose();
					host.requestFrame();
				case _:
			}
		});
		active = this;
		opened = true;
	}

	function matches(source:Handle):Bool
		return source.rawValue() == host.window.rawValue() || source.rawValue() == host.surface.rawValue();

	function openGraphics():Void {
		if (graphics != null) return;
		var text:Null<String> = null;
		if (config.benchmark == TextHeavy) {
			var repeated = new StringBuf();
			for (_ in 0...8)
				repeated.add("NativeKit — مرحبا — שלום — こんにちは 👋 · ");
			text = repeated.toString();
		}
		var lab = new Showcase(host.fonts, text, false);
		if (config.benchmark == Static) lab.setBenchmarkAnimation(false);
		graphics = lab;
		startedAt = null;
		renderCount = 0;
		host.requestFrame();
	}

	public function context():UiContext return explorer.hostContext();

	public function submit(frame:LayoutFrame):RenderNode
		return explorer.submitHostFrame(frame);

	public function submitFrame(frame:SurfaceFrame, info:FrameInfo, timeSeconds:Float):Bool {
		var lab = graphics;
		if (lab == null) return false;
		if (config.benchmark == Editing) lab.benchmarkTextEdit(renderCount);
		if (startedAt == null) startedAt = timeSeconds;
		var elapsed = Math.max(0.0, timeSeconds - startedAt);
		lab.encodeFrame(elapsed, info.logicalWidth, info.logicalHeight, info.framebufferWidth,
			info.framebufferHeight, info.pixelScale, false);
		lab.submitFrame(frame, info);
		renderCount++;
		host.requestFrame();
		return true;
	}

	public function dispose():Void {
		if (active == this) active = null;
		defer explorer.dispose();
		defer if (graphics != null) graphics.dispose();
		if (input != null) input.dispose();
	}

	public static function caretOffset():Int
		return active == null || active.graphics == null ? -1 : active.graphics.caretOffset();

	public static function caretAffinity():Int
		return active == null || active.graphics == null ? -1 : active.graphics.caretAffinity();

	public static function caretDirection():Int
		return active == null || active.graphics == null ? -1 : active.graphics.caretDirection();
}
