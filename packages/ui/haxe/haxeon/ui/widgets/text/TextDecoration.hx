package haxeon.ui.widgets.text;

import haxeon.ui.TextLayout.TextPosition;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Rect;
import haxeon.ui.PathBuilder;

/** Immutable decoration in absolute document codepoint coordinates. */
class TextDecoration {
	public final start:Int;
	public final end:Int;
	public final color:Color;
	public final kind:TextDecorationKind;

	public function new(start:Int, end:Int, color:Color, kind:TextDecorationKind) {
		if (start < 0 || end < start || color == null || kind == null)
			throw "Text decoration arguments are invalid";
		if (start == end && kind != WholeLineBackground)
			throw "Only a whole-line decoration may have an empty range";
		this.start = start;
		this.end = end;
		this.color = color;
		this.kind = kind;
	}

	/** Reuses shaped range geometry, merging adjacent grapheme rectangles. */
	public function rectangles(layout:TextEditorLayout, minY:Float, maxY:Float):Array<Rect> {
		var rects:Array<Rect> = [];
		if (start == end) {
			var caret = layout.caret(new TextPosition(start, 0));
			var top = caret.y + Math.min(caret.ascender, caret.descender);
			var height = Math.abs(caret.descender - caret.ascender);
			if (top + height > minY && top < maxY)
				rects.push(new Rect(0.0, top, layout.width, Math.max(1.0, height)));
		} else if (kind == WholeLineBackground) {
			for (rect in layout.wholeLineRects(start, end, minY, maxY))
				rects.push(rect);
		} else {
			for (rect in layout.selectionRangeRects(new TextPosition(start, 0),
				new TextPosition(end, 0), minY, maxY))
				rects.push(new Rect(rect.x, rect.y, rect.width, rect.height));
		}
		rects.sort(function(a, b) {
			if (a.y < b.y) return -1;
			if (a.y > b.y) return 1;
			return a.x < b.x ? -1 : a.x > b.x ? 1 : 0;
		});
		var merged:Array<Rect> = [];
		for (rect in rects) {
			if (rect.width <= 0.0 || rect.height <= 0.0)
				continue;
			var previous = merged.length == 0 ? null : merged[merged.length - 1];
			if (previous != null && Math.abs(previous.y - rect.y) < 0.01 &&
				Math.abs(previous.height - rect.height) < 0.01 &&
				rect.x <= previous.x + previous.width + 0.01)
				merged[merged.length - 1] = new Rect(previous.x, previous.y,
					Math.max(previous.x + previous.width, rect.x + rect.width) - previous.x,
					previous.height);
			else
				merged.push(rect);
		}
		return merged;
	}

	/** Clips horizontal work to the viewport, including the wavy path's segment count. */
	public function paint(canvas:Canvas, rects:Array<Rect>, minX:Float, maxX:Float):Void {
		for (rect in rects) {
			var left = Math.max(minX, rect.x);
			var right = Math.min(maxX, rect.x + rect.width);
			if (right <= left)
				continue;
			switch kind {
				case Background, WholeLineBackground:
					canvas.fillRectIfPositive(new Rect(left, rect.y, right - left, rect.height), color);
				case Underline:
					canvas.fillRectIfPositive(new Rect(left, rect.y + rect.height - 1.0,
						right - left, 1.0), color);
				case WavyUnderline:
					var baseline = rect.y + rect.height - 2.0;
					var path = new PathBuilder().moveTo(left, baseline);
					var x = left;
					var direction = 1.0;
					while (x < right) {
						var endX = Math.min(right, x + 3.0);
						path.quadraticTo((x + endX) * 0.5, baseline + direction * 2.0,
							endX, baseline);
						direction = -direction;
						x = endX;
					}
					canvas.strokeTransient(path.build(), color, 1.0);
			}
		}
	}
}
