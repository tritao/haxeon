package haxeon.ui.style;

import haxeon.ui.Canvas;
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
			case DecorationKind.Outline: "outline";
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
