package haxeon.ui.style;

import haxeon.ui.Image;

/**
 * Rendering-independent source-alpha mask description. Masks are discrete
 * composition inputs; their shape and resource identity do not interpolate.
 */
class Mask {
	/** The mask's shape. */
	public final kind:MaskKind;

	/** The corner radius of a rounded rectangle, or a circle's radius. */
	public final radius:Float;

	/** A gradient's start, horizontally, as a fraction of the width. */
	public final x0:Float;

	/** A gradient's start, vertically. */
	public final y0:Float;

	/** A gradient's end, horizontally. */
	public final x1:Float;

	/** A gradient's end, vertically. */
	public final y1:Float;

	/** The opacity at a gradient's start. */
	public final alpha0:Float;

	/** The opacity at its end. */
	public final alpha1:Float;

	/** An image mask's image, whose alpha is used. */
	public final image:Null<Image>;

	function new(kind:MaskKind, radius:Float, x0:Float, y0:Float, x1:Float, y1:Float,
			alpha0:Float, alpha1:Float, image:Null<Image>) {
		if (kind == null)
			throw "Mask kind is required";
		for (value in [radius, x0, y0, x1, y1, alpha0, alpha1])
			if (!Math.isFinite(value))
				throw "Mask parameters must be finite";
		if ((kind == MaskKind.RoundedRect || kind == MaskKind.Circle) && radius < 0.0)
			throw "Mask radius must be non-negative";
		if (kind == MaskKind.LinearGradient && (alpha0 < 0.0 || alpha0 > 1.0 || alpha1 < 0.0 || alpha1 > 1.0))
			throw "Mask gradient alpha must be in the range 0..1";
		if (kind == MaskKind.Image && (image == null || image.isDisposed()))
			throw "Image masks require a live image";
		if (kind != MaskKind.Image && image != null)
			throw "Only image masks may reference an image";
		this.kind = kind;
		this.radius = radius;
		this.x0 = x0;
		this.y0 = y0;
		this.x1 = x1;
		this.y1 = y1;
		this.alpha0 = alpha0;
		this.alpha1 = alpha1;
		this.image = image;
	}

	/** Masks to the box. */
	public static function rectangle():Mask
		return new Mask(MaskKind.Rectangle, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, null);

	/** Masks to the box with corners of `radius`. Throws when it is negative. */
	public static function roundedRect(radius:Float):Mask
		return new Mask(MaskKind.RoundedRect, radius, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, null);

	/** Masks to a circle of `radius`. Throws when it is negative. */
	public static function circle(radius:Float):Mask
		return new Mask(MaskKind.Circle, radius, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, null);

	/** Coordinates are normalized to the isolated target (0..1 is typical). */
	public static function linearGradient(x0:Float, y0:Float, x1:Float, y1:Float,
			alpha0:Float = 0.0, alpha1:Float = 1.0):Mask
		return new Mask(MaskKind.LinearGradient, 0.0, x0, y0, x1, y1, alpha0, alpha1, null);

	/** Masks by `image`'s alpha. Throws when the image is disposed. */
	public static function fromImage(image:Image):Mask
		return new Mask(MaskKind.Image, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, image);

	/** An equal mask. */
	public function copy():Mask
		return new Mask(kind, radius, x0, y0, x1, y1, alpha0, alpha1, image);

	/** By hand: the image is compared by identity, which the generated equality does not do for a plain class. */
	public function isEqual(other:Mask):Bool
		return other != null && kind == other.kind && radius == other.radius && x0 == other.x0 && y0 == other.y0 && x1
			== other.x1 && y1 == other.y1 && alpha0 == other.alpha0 && alpha1 == other.alpha1 && image == other.image;

	/** A description for inspection. */
	public function describe():String {
		return switch kind {
			case MaskKind.Rectangle: "rectangle";
			case MaskKind.RoundedRect: 'rounded-rect($radius)';
			case MaskKind.Circle: 'circle($radius)';
			case MaskKind.LinearGradient: 'linear-gradient($x0,$y0,$x1,$y1,$alpha0,$alpha1)';
			case MaskKind.Image:
				var source:Image = cast image;
				'image(${source.width}x${source.height})';
			default: "mask";
		};
	}

	/** A description for inspection. */
	public function toString():String
		return describe();
}

/** Typed source-alpha mask families understood by the native compositor. */
typedef MaskKind = NativeKitUI.UiMaskKind;
