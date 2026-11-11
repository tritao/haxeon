import haxeon.ui.Color;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.PaintBindings;
import haxeon.ui.PaintStore;

function main():Int {
	scoped var paint = new PaintStore();
	scoped var otherPaint = new PaintStore();
	var style = new LayoutStyle();
	style.background = Color.rgba(0.1, 0.2, 0.3, 1);
	style.radiusTopLeft = 2.5;
	var first = new LayoutNode(1, haxeon.ui.LayoutVisualKind.Box, style);
	var second = new LayoutNode(2, haxeon.ui.LayoutVisualKind.Box, style);
	var firstIndex = paint.acquire(), secondIndex = paint.acquire();
	var a = PaintBindings.attach(first, paint, firstIndex), b = PaintBindings.attach(second, paint, secondIndex);
	var otherIndex = otherPaint.acquire(), c = PaintBindings.attach(first, otherPaint, otherIndex);
	paint.acknowledge(firstIndex, a.generation);
	paint.acknowledge(secondIndex, b.generation);
	style.background = Color.rgba(0.4, 0.5, 0.6, 1);
	style.radiusTopLeft = 3.25;
	first.textColor = Color.rgba(0.7, 0.8, 0.9, 1);
	if (!paint.isDirty(firstIndex, a.generation) || !paint.isDirty(secondIndex, b.generation) ||
		paint.at(firstIndex, a.generation).ref.backgroundRed != 0.4 ||
		otherPaint.at(otherIndex, c.generation).ref.backgroundRed != 0.4 ||
		otherPaint.at(otherIndex, c.generation).ref.textRed != 0.7 ||
		paint.at(secondIndex, b.generation).ref.backgroundRed != 0.4 ||
		paint.at(secondIndex, b.generation).ref.radiusTopLeft != 3.25 ||
		paint.at(firstIndex, a.generation).ref.textRed != 0.7 ||
		paint.at(secondIndex, b.generation).ref.textRed != 1.0 ||
		style.background.red != 0.4 || first.textColor.red != 0.7 ||
		haxeon.Diff.mask(style, style.copy()) != 0) return 1;
	paint.acknowledge(firstIndex, a.generation);
	paint.acknowledge(secondIndex, b.generation);
	style.background = Color.rgba(0.4, 0.5, 0.6, 1);
	style.radiusTopLeft = 3.25;
	first.textColor = Color.rgba(0.7, 0.8, 0.9, 1);
	if (paint.isDirty(firstIndex, a.generation) || paint.isDirty(secondIndex, b.generation)) return 4;
	var negativeZero = -1.0 / Math.POSITIVE_INFINITY;
	style.radiusBottomLeft = negativeZero;
	if (1.0 / style.radiusBottomLeft != Math.NEGATIVE_INFINITY || !paint.isDirty(firstIndex, a.generation)) return 5;
	PaintBindings.detach(a);
	paint.release(firstIndex, a.generation);
	if (first.textColor.red != 0.7 || style.background.red != 0.4) return 2;
	PaintBindings.detach(c);
	otherPaint.release(otherIndex, c.generation);
	if (first.textColor.red != 0.7) return 6;
	PaintBindings.detach(b);
	paint.release(secondIndex, b.generation);
	if (style.background.red != 0.4 || style.radiusTopLeft != 3.25 || second.textColor.red != 1.0) return 3;
	return 42;
}
