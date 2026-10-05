package nativekit.ui.host;

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
