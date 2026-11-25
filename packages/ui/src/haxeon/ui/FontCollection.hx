package haxeon.ui;

/** Collection of fonts used to create text layouts. */
import haxe.io.Bytes;

/** The fonts text is shaped with, loaded from files and grouped by family. */
class FontCollection extends NativeKitUIResource {
	private function new(value:nkui_resource)
		super(value);

	/** An empty collection. */
	public static function create():FontCollection {
		var made = NativeKitUI.nkui_font_collection_create();
		UiResult.check(made.status, "fonts.create");
		return new FontCollection(made.out_fonts);
	}

	/** Loads the font file at `path` into the family `family`. */
	public function add(path:String, family:FontFamily = FontFamily.Default):Void
		UiResult.check(NativeKitUI.nkui_font_collection_add(nativeHandle(), path, family), "fonts.add");

	/** Adds font bytes, which is useful when a browser asset has been fetched into memory. */
	public function addData(name:String, data:Bytes, family:FontFamily = FontFamily.Default):Void
		UiResult.check(NativeKitUI.nkui_font_collection_add_data(nativeHandle(), name, data,
			family), "fonts.addData");

	/** Adds the bundled browser font or enables platform system-font fallback discovery. */
	public function addDefaultFonts():Void
		UiResult.check(NativeKitUI.nkui_font_collection_add_default_fonts(nativeHandle()),
			"fonts.addDefaultFonts");
}

/** Font roles used by a FontCollection. */
typedef FontFamily = NativeKitUI.UiFontFamily;
