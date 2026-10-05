package nativekit.ui.host;

import FontFamily;

/** One application-provided browser font; BrowserUiHost has no document defaults. */
class BrowserUiFontAsset {
	public final name:String;
	public final uri:String;
	public final bundledPath:String;
	public final family:FontFamily;

	public function new(name:String, uri:String, bundledPath:String, family:FontFamily) {
		this.name = name;
		this.uri = uri;
		this.bundledPath = bundledPath;
		this.family = family;
	}
}

class BrowserUiHostOptions extends UiHostOptions {
	public var fonts:Array<BrowserUiFontAsset> = [];

	public function new() super();

	override public function validate():Void {
		if (title == null || title.length == 0 || width <= 0 || height <= 0 ||
			eventQueueCapacity <= 0)
			throw "Browser UI host options are invalid";
		if (fonts == null) throw "Browser UI font assets cannot be null";
		for (font in fonts)
			if (font == null || font.name == null || font.name.length == 0 ||
				font.uri == null || font.uri.length == 0 || font.bundledPath == null ||
				font.bundledPath.length == 0)
				throw "Browser UI font asset is invalid";
	}
}
