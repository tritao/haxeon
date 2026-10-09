package haxeon.ui.style;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;

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
		var borderColor = color == null ? style.get(StyleProperty.BorderColor) : color;
		var borderWidth = width == null ? style.get(StyleProperty.BorderWidth) : width;
		if (borderColor == null || borderWidth <= 0.0)
			return;
		if (geometry.width <= 0.0 || geometry.height <= 0.0)
			return;
		canvas.drawRectBorder(new Rect(0.0, 0.0, geometry.width, geometry.height), hairline ? 0.0 : borderWidth, borderColor);
	}

	override public function copy():Decoration
		return new BorderDecoration(color, width, hairline);

	override public function isEqual(other:Decoration):Bool {
		if (other == null || other.kind != kind)
			return false;
		var value:BorderDecoration = cast other;
		return Effect.equalColor(color, value.color) && width == value.width && hairline == value.hairline;
	}

	override public function interpolate(other:Decoration, amount:Float):Decoration {
		if (other == null || other.kind != kind)
			return Decoration.discrete(this, other, amount);
		var value:BorderDecoration = cast other;
		if (hairline != value.hairline || color == null || value.color == null || width == null || value.width == null)
			return amount < 0.5 ? copy() : value.copy();
		return new BorderDecoration(Effect.interpolateColor(color, value.color, amount),
			width + (value.width - width) * amount, hairline);
	}

	override public function describe():String
		return 'border(${color == null ? "style" : color.red + "," + color.green + "," +
			color.blue + "," + color.alpha},${width == null ? "style" : width},${hairline ? "hairline" : "logical"})';
}
