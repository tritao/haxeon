package haxeon.ui.style;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Image;
import haxeon.ui.Paint;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;

/**
 * Rendering-independent decoration value painted after layout resolves geometry.
 *
 * Decorations deliberately follow the same value-object contract as VisualEffect:
 * built-ins override copy/equality/interpolation, while custom decorations can
 * inherit the identity/discrete defaults without any runtime type inspection.
 */
class Decoration {
	/** Which decoration this is: a built-in family, or `Custom` for one an application defines. */
	public final kind:DecorationKind;

	/** A decoration of `kind`; a custom decoration passes nothing. */
	public function new(kind:DecorationKind = DecorationKind.Custom)
		this.kind = kind;

	/** Paints this decoration in node-local coordinates; the base value paints nothing. */
	public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void {}

	/** Returns an independent value copy when the decoration has mutable state. */
	public function copy():Decoration
		return this;

	/** Compares the complete semantic value, not just the decoration family. */
	public function isEqual(other:Decoration):Bool
		return other == this;

	/** Interpolates compatible values; custom decorations switch discretely. */
	public function interpolate(other:Decoration, amount:Float):Decoration
		return Decoration.discrete(this, other, amount);

	/** The decoration as a short readable text, such as `border`, which the inspector and style dumps show. */
	public function describe():String
		return switch kind {
			case DecorationKind.Background: "background";
			case DecorationKind.Gradient: "gradient";
			case DecorationKind.Image: "image";
			case DecorationKind.NineSlice: "nine-slice";
			case DecorationKind.Border: "border";
			case DecorationKind.Shadow: "shadow";
			case DecorationKind.Custom: "custom";
		};

	/** The same text as `describe`. */
	public function toString():String
		return describe();

	/** A copy of `left` before the midpoint of `amount`, and of `right` (or `left` without one) from it on. */
	public static function discrete(left:Decoration, right:Decoration,
			amount:Float):Decoration
		return amount < 0.5 || right == null ? left.copy() : right.copy();
}

/** Typed decoration families understood by the style and paint systems. */
enum DecorationKind implements Equatable {
	Background;
	Gradient;
	Image;
	NineSlice;
	Border;
	Shadow;
	/** A user-defined renderer-owned decoration. */
	Custom;
}

/** Ordered, value-aware collection of post-layout style decorations. */
class DecorationChain {
	public final decorations:Array<Decoration>;

	public function new(decorations:Array<Decoration> = null) {
		this.decorations = [];
		if (decorations != null)
			for (decoration in decorations) {
				if (decoration == null)
					throw "Decoration chains cannot contain null decorations";
				this.decorations.push(decoration.copy());
			}
	}

	public static function empty():DecorationChain
		return new DecorationChain();

	public static function of(decorations:Array<Decoration>):DecorationChain
		return new DecorationChain(decorations);

	public function copy():DecorationChain
		return new DecorationChain(decorations);

	public function isEqual(other:DecorationChain):Bool {
		if (other == null || decorations.length != other.decorations.length)
			return false;
		for (index in 0...decorations.length)
			if (!equalDecoration(decorations[index], other.decorations[index]))
				return false;
		return true;
	}

	/** Interpolates the ordered decoration values, preserving chain shape. */
	public static function interpolate(left:DecorationChain, right:DecorationChain,
			amount:Float):DecorationChain {
		if (left == null)
			return right == null ? empty() : right.copy();
		if (right == null)
			return left.copy();
		if (left.decorations.length != right.decorations.length)
			return amount < 0.5 ? left.copy() : right.copy();
		var result:Array<Decoration> = [];
		for (index in 0...left.decorations.length)
			result.push(left.decorations[index].interpolate(right.decorations[index], amount));
		return new DecorationChain(result);
	}

	/** Stable cache and inspection key for the resolved decoration sequence. */
	public function key():String {
		var values:Array<String> = [];
		for (decoration in decorations)
			values.push(decoration.describe());
		return values.join("|");
	}

	public function toString():String
		return "[" + key() + "]";

	static function equalDecoration(left:Decoration, right:Decoration):Bool {
		if (left == right)
			return true;
		return left.isEqual(right);
	}
}

/** Paints the computed background as a custom decoration when native fill is unsuitable. */
class BackgroundDecoration extends Decoration {
	public final color:Null<Color>;

	public function new(?color:Color) {
		super(DecorationKind.Background);
		this.color = color == null ? null : VisualEffect.copyColor(color);
	}

	override public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void {
		var resolved = color == null ? style.getColor(StyleProperty.Background) : color;
		canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height),
			resolved);
	}

	override public function copy():Decoration
		return new BackgroundDecoration(color);

	override public function isEqual(other:Decoration):Bool {
		if (other == null || other.kind != kind)
			return false;
		var value:BackgroundDecoration = cast other;
		return VisualEffect.equalColor(color, value.color);
	}

	override public function interpolate(other:Decoration, amount:Float):Decoration {
		if (other == null || other.kind != kind)
			return Decoration.discrete(this, other, amount);
		var value:BackgroundDecoration = cast other;
		if (color == null || value.color == null)
			return amount < 0.5 ? copy() : value.copy();
		return new BackgroundDecoration(VisualEffect.interpolateColor(color, value.color, amount));
	}

	override public function describe():String
		return color == null
			? "background(style)" : 'background(${color.red},${color.green},${color.blue},${color.alpha})';
}

/** Inset solid border aligned by the renderer at the final device transform. */
class BorderDecoration extends Decoration {
	public final color:Null<Color>;
	public final width:Null<Float>;
	/** Fixed one-device-pixel outline instead of a scaled logical width. */
	public final hairline:Bool;

	public function new(?color:Color, ?width:Float, hairline:Bool = false) {
		super(DecorationKind.Border);
		this.color = color;
		this.width = width;
		this.hairline = hairline;
	}

	/** Width remains one device pixel on axis-aligned surfaces at every zoom. */
	public static function deviceHairline(?color:Color):BorderDecoration
		return new BorderDecoration(color, null, true);

	override public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void {
		var borderColor = color == null ? style.getColor(StyleProperty.BorderColor) : color;
		var borderWidth = width == null ? style.getNumber(StyleProperty.BorderWidth) : width;
		if (borderWidth <= 0.0)
			return;
		if (geometry.width <= 0.0 || geometry.height <= 0.0)
			return;
		canvas.drawRectBorder(new Rect(0.0, 0.0, geometry.width, geometry.height), hairline ? 0.0 : borderWidth,
			borderColor);
	}

	override public function copy():Decoration
		return new BorderDecoration(color, width, hairline);

	override public function isEqual(other:Decoration):Bool {
		if (other == null || other.kind != kind)
			return false;
		var value:BorderDecoration = cast other;
		return VisualEffect.equalColor(color, value.color) && width == value.width && hairline == value.hairline;
	}

	override public function interpolate(other:Decoration, amount:Float):Decoration {
		if (other == null || other.kind != kind)
			return Decoration.discrete(this, other, amount);
		var value:BorderDecoration = cast other;
		if (hairline != value.hairline || color == null || value.color == null || width == null || value.width == null)
			return amount < 0.5 ? copy() : value.copy();
		return new BorderDecoration(VisualEffect.interpolateColor(color, value.color, amount),
			width + (value.width - width) * amount, hairline);
	}

	override public function describe():String
		return 'border(${color == null ? "style" : color.red + "," + color.green + "," +
			color.blue + "," + color.alpha},${width == null ? "style" : width},${hairline ? "hairline" : "logical"})';
}

/** Horizontal linear gradient backed by the renderer's native gradient paint. */
class GradientDecoration extends Decoration {
	public final start:Color;
	public final end:Color;

	public function new(start:Color, end:Color) {
		super(DecorationKind.Gradient);
		this.start = VisualEffect.copyColor(start);
		this.end = VisualEffect.copyColor(end);
	}

	override public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void {
		canvas.fillLinearGradientRect(new Rect(0.0, 0.0, geometry.width, geometry.height),
			0.0, 0.0, geometry.width, 0.0,
			[
				new GradientStop(0.0, start),
				new GradientStop(1.0, end)
			]);
	}

	override public function copy():Decoration
		return new GradientDecoration(start, end);

	override public function isEqual(other:Decoration):Bool {
		if (other == null || other.kind != kind)
			return false;
		var value:GradientDecoration = cast other;
		return VisualEffect.equalColor(start, value.start) && VisualEffect.equalColor(end, value.end);
	}

	override public function interpolate(other:Decoration, amount:Float):Decoration {
		if (other == null || other.kind != kind)
			return Decoration.discrete(this, other, amount);
		var value:GradientDecoration = cast other;
		return new GradientDecoration(VisualEffect.interpolateColor(start, value.start, amount),
			VisualEffect.interpolateColor(end, value.end, amount));
	}

	override public function describe():String
		return 'linear-gradient(${start.red},${start.green},${start.blue},${start.alpha},'
			+ '${end.red},${end.green},${end.blue},${end.alpha})';
}

/** Fills the resolved node bounds with an image. */
class ImageDecoration extends Decoration {
	public final image:Image;

	public function new(image:Image) {
		super(DecorationKind.Image);
		if (image == null || image.isDisposed())
			throw "Image decorations require a live image";
		this.image = image;
	}

	override public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void
		canvas.drawImage(image, new Rect(0.0, 0.0, geometry.width, geometry.height));

	override public function copy():Decoration
		return new ImageDecoration(image);

	override public function isEqual(other:Decoration):Bool {
		if (other == null || other.kind != kind)
			return false;
		return image == cast(other, ImageDecoration).image;
	}

	override public function interpolate(other:Decoration, amount:Float):Decoration
		return Decoration.discrete(this, other, amount);

	override public function describe():String
		return 'image(${image.identity},${image.width}x${image.height})';
}

/** Draws an image as nine independently clipped, stretched slices. */
class NineSliceDecoration extends Decoration {
	public final image:Image;
	public final left:Float;
	public final top:Float;
	public final right:Float;
	public final bottom:Float;

	public function new(image:Image, left:Float, top:Float, right:Float, bottom:Float) {
		super(DecorationKind.NineSlice);
		if (image == null || image.isDisposed() || left < 0.0 || top < 0.0 || right < 0.0 || bottom < 0.0)
			throw "Nine-slice decorations require a live image and non-negative insets";
		this.image = image;
		this.left = left;
		this.top = top;
		this.right = right;
		this.bottom = bottom;
	}

	override public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void {
		if (geometry.width <= 0.0 || geometry.height <= 0.0)
			return;
		var sourceLeft = Math.min(left, image.width);
		var sourceTop = Math.min(top, image.height);
		var sourceRight = Math.min(right, image.width - sourceLeft);
		var sourceBottom = Math.min(bottom, image.height - sourceTop);
		var destinationLeft = Math.min(left, geometry.width * 0.5);
		var destinationTop = Math.min(top, geometry.height * 0.5);
		var destinationRight = Math.min(right, geometry.width - destinationLeft);
		var destinationBottom = Math.min(bottom, geometry.height - destinationTop);
		var sourceX:Array<Float> = [0.0, sourceLeft, image.width - sourceRight];
		var sourceY:Array<Float> = [0.0, sourceTop, image.height - sourceBottom];
		var sourceWidth:Array<Float> = [sourceLeft,
			image.width - sourceLeft - sourceRight, sourceRight];
		var sourceHeight:Array<Float> = [sourceTop,
			image.height - sourceTop - sourceBottom, sourceBottom];
		var destinationX:Array<Float> = [0.0, destinationLeft, geometry.width - destinationRight];
		var destinationY:Array<Float> = [0.0, destinationTop, geometry.height - destinationBottom];
		var destinationWidth:Array<Float> = [
			destinationLeft,
			geometry.width - destinationLeft - destinationRight,
			destinationRight
		];
		var destinationHeight:Array<Float> = [
			destinationTop,
			geometry.height - destinationTop - destinationBottom,
			destinationBottom
		];
		for (column in 0...3)
			for (row in 0...3) {
				var sourceWidthValue = sourceWidth[column];
				var sourceHeightValue = sourceHeight[row];
				var destinationWidthValue = destinationWidth[column];
				var destinationHeightValue = destinationHeight[row];
				if (sourceWidthValue <= 0.0 || sourceHeightValue <= 0.0 || destinationWidthValue <= 0.0
					|| destinationHeightValue <= 0.0)
					continue;
				var sourceOriginX = sourceX[column];
				var sourceOriginY = sourceY[row];
				var destinationOriginX = destinationX[column];
				var destinationOriginY = destinationY[row];
				canvas.withClip(new Rect(destinationOriginX, destinationOriginY,
					destinationWidthValue, destinationHeightValue), function(target) {
						target.translate(destinationOriginX - sourceOriginX * destinationWidthValue / sourceWidthValue,
							destinationOriginY - sourceOriginY * destinationHeightValue / sourceHeightValue);
						target.scale(destinationWidthValue / sourceWidthValue,
							destinationHeightValue / sourceHeightValue);
						target.drawImage(image, new Rect(0.0, 0.0, image.width, image.height));
					});
			}
	}

	override public function copy():Decoration
		return new NineSliceDecoration(image, left, top, right, bottom);

	override public function isEqual(other:Decoration):Bool {
		if (other == null || other.kind != kind)
			return false;
		var value:NineSliceDecoration = cast other;
		return image == value.image && left == value.left && top == value.top && right == value.right
			&& bottom == value.bottom;
	}

	override public function interpolate(other:Decoration, amount:Float):Decoration {
		if (other == null || other.kind != kind)
			return Decoration.discrete(this, other, amount);
		var value:NineSliceDecoration = cast other;
		if (image != value.image)
			return amount < 0.5 ? copy() : value.copy();
		return new NineSliceDecoration(image, left + (value.left - left) * amount,
			top + (value.top - top) * amount, right + (value.right - right) * amount,
			bottom + (value.bottom - bottom) * amount);
	}

	override public function describe():String
		return 'nine-slice(${Std.string(image)},$left,$top,$right,$bottom)';
}

/** Geometry-based rounded-rectangle shadow; distinct from subtree DropShadowEffect. */
class ShadowDecoration extends Decoration {
	public final color:Null<Color>;
	public final offsetX:Null<Float>;
	public final offsetY:Null<Float>;
	/** Optional UI-facing blur radius override. */
	public final blurRadius:Null<Float>;
	public final spread:Null<Float>;

	public function new(?color:Color, ?offsetX:Float, ?offsetY:Float, ?blurRadius:Float, ?spread:Float) {
		super(DecorationKind.Shadow);
		this.color = color;
		this.offsetX = offsetX;
		this.offsetY = offsetY;
		this.blurRadius = blurRadius;
		this.spread = spread;
	}

	override public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void {
		var shadowColor = color == null ? style.getColor(StyleProperty.ShadowColor) : color;
		var x = offsetX == null ? style.getNumber(StyleProperty.ShadowOffsetX) : offsetX;
		var y = offsetY == null ? style.getNumber(StyleProperty.ShadowOffsetY) : offsetY;
		var radius = blurRadius == null ? style.getNumber(StyleProperty.ShadowBlur) : blurRadius;
		if (shadowColor == null || shadowColor.alpha <= 0.0)
			return;
		var topLeft = style.getNumber(StyleProperty.RadiusTopLeft);
		var topRight = style.getNumber(StyleProperty.RadiusTopRight);
		var bottomRight = style.getNumber(StyleProperty.RadiusBottomRight);
		var bottomLeft = style.getNumber(StyleProperty.RadiusBottomLeft);
		var resolvedSpread = spread == null ? style.getNumber(StyleProperty.ShadowSpread) : spread;
		canvas.drawBoxShadow(new Rect(0.0, 0.0, geometry.width, geometry.height), x, y, radius,
			resolvedSpread, [
				topLeft,
				topRight,
				bottomRight,
				bottomLeft
			], shadowColor);
	}

	override public function copy():Decoration
		return new ShadowDecoration(color, offsetX, offsetY, blurRadius, spread);

	override public function isEqual(other:Decoration):Bool {
		if (other == null || other.kind != kind)
			return false;
		var value:ShadowDecoration = cast other;
		return VisualEffect.equalColor(color, value.color) && offsetX == value.offsetX && offsetY == value.offsetY
			&& blurRadius == value.blurRadius && spread == value.spread;
	}

	override public function interpolate(other:Decoration, amount:Float):Decoration {
		if (other == null || other.kind != kind)
			return Decoration.discrete(this, other, amount);
		var value:ShadowDecoration = cast other;
		if (color == null || value.color == null || offsetX == null || value.offsetX == null || offsetY == null
			|| value.offsetY == null || blurRadius == null || value.blurRadius == null || spread == null
			|| value.spread == null)
			return amount < 0.5 ? copy() : value.copy();
		return new ShadowDecoration(VisualEffect.interpolateColor(color, value.color, amount),
			offsetX + (value.offsetX - offsetX) * amount,
			offsetY + (value.offsetY - offsetY) * amount,
			blurRadius + (value.blurRadius - blurRadius) * amount,
			spread + (value.spread - spread) * amount);
	}

	override public function describe():String
		return 'shadow(${color == null ? "style" : color.red + "," + color.green + "," +
			color.blue + "," + color.alpha},${offsetX == null ? "style" : offsetX},'
			+ '${offsetY == null ? "style" : offsetY},${blurRadius == null ? "style" : blurRadius},'
			+ '${spread == null ? "style" : spread})';
}
