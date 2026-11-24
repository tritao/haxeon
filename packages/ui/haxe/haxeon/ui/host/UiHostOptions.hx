package haxeon.ui.host;

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
