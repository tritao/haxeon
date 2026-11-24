package haxeon.ui.host;

import haxeon.ui.FontFamily;

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
