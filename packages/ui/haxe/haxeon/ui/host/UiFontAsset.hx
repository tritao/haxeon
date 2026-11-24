package haxeon.ui.host;

import haxeon.ui.FontFamily;

/** A browser font with external and bundled locations. */
class UiFontAsset {
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
