package haxeon.ui;

import haxe.io.Bytes;

/** An immutable image resource uploaded to the UI renderer. */
class Image extends NativeKitUIResource {
	static var nextIdentity:Int = 1;

	/** Stable process-local identity used by value caches and diagnostics. */
	public final identity:Int;

	/** Its width, in pixels. */
	public final width:Int;

	/** Its height, in pixels. */
	public final height:Int;

	/** How its pixels are stored. */
	public final format:ImageFormat;

	/** How it is sampled when drawn larger or smaller. */
	public final filter:ImageFilter;

	private function new(value:nkui_resource, width:Int, height:Int, format:ImageFormat,
			filter:ImageFilter) {
		super(value);
		identity = nextIdentity++;
		this.width = width;
		this.height = height;
		this.format = format;
		this.filter = filter;
	}

	/** An image of `pixels`, uploaded to the renderer. Throws when the pixels do not match the size and format. */
	public static function create(width:Int, height:Int, format:ImageFormat, pixels:Bytes,
			filter:ImageFilter = ImageFilter.Linear):Image {
		if (width <= 0 || height <= 0)
			throw "Image dimensions must be positive";
		var bytesPerPixel = format == ImageFormat.R8 ? 1 : format == ImageFormat.Rgba8 ? 4 : 0;
		if (bytesPerPixel == 0 || pixels == null || pixels.length != width * height * bytesPerPixel)
			throw "Image pixel data does not match its dimensions and format";
		var made = NativeKitUI.nkui_image_create_filtered(width, height, format, pixels,
			filter);
		UiResult.check(made.status, "image.create");
		return new Image(made.out_image, width, height, format, filter);
	}

	/** Synchronously decodes an image file. Use an application worker for blocking I/O. */
	public static function loadFile(path:String,
			filter:ImageFilter = ImageFilter.Linear):Image {
		if (path == null || path.length == 0)
			throw "Image path must not be empty";
		var made = NativeKitUI.nkui_image_load_file(path, filter);
		UiResult.check(made.status, "image.loadFile");
		return new Image(made.out_image, made.out_width, made.out_height,
			ImageFormat.Rgba8, filter);
	}
}

/** Texture sampling used when an image is drawn larger or smaller than its source. */
typedef ImageFilter = NativeKitUI.UiImageFilter;

/** Pixel formats accepted by Image.create. */
typedef ImageFormat = NativeKitUI.UiImageFormat;
