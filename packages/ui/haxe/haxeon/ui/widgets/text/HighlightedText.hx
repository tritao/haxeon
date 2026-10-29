package haxeon.ui.widgets.text;

import haxeon.ui.*;
import haxeon.ui.core.*;
import haxeon.ui.theme.TextRole;
import haxeon.editor.TextDocument;

/** Search marking without splitting text runs or changing their wrapping. */
class HighlightedText implements View {
	final value:String;
	final query:String;
	final style:Null<LayoutStyle>;
	final color:Null<Color>;
	final textStyle:Null<TextStyleOverride>;
	final role:Null<TextRole>;
	public function new(value:String, query:String, ?style:LayoutStyle, ?color:Color,
		?textStyle:TextStyleOverride, ?role:TextRole) {
		this.value = value; this.query = query; this.style = style;
		this.color = color; this.textStyle = textStyle; this.role = role;
	}

	/** Native text ranges use codepoints; String searches use target-specific offsets. */
	public static function matches(value:String, query:String):Array<{start:Int, end:Int}> {
		var result:Array<{start:Int, end:Int}> = [];
		var lower = value.toLowerCase();
		for (term in ~/\s+/g.split(StringTools.trim(query).toLowerCase())) {
			if (term.length == 0) continue;
			var offset = 0;
			while (offset < lower.length) {
				var found = lower.indexOf(term, offset);
				if (found < 0) break;
				result.push({start: new TextDocument(value.substr(0, found)).codepointCount,
					end: new TextDocument(value.substr(0, found + term.length)).codepointCount});
				offset = found + term.length;
			}
		}
		result.sort(function(a, b) return a.start - b.start);
		var merged:Array<{start:Int, end:Int}> = [];
		for (range in result) {
			var previous = merged.length == 0 ? null : merged[merged.length - 1];
			if (previous != null && range.start <= previous.end) previous.end = Std.int(Math.max(previous.end, range.end));
			else merged.push(range);
		}
		return merged;
	}

	public function build(context:BuildContext):RenderNode {
		var node = new Text(value, style, color, textStyle, role).build(context);
		var ranges = matches(value, query);
		var fonts = context.fonts;
		if (ranges.length == 0 || fonts == null) return node;
		var text = node.layout.textStyle, paragraph = node.layout.paragraphStyle;
		var foreground = node.layout.textColor, accent = context.theme.tokens.accent;
		var resource = context.resourceState(context.id("highlight-layout"),
			function() return new SearchTextLayout(fonts), function(layout) layout.dispose()).value;
		resource.update(value, text, paragraph, foreground,
			Color.rgba(accent.red, accent.green, accent.blue, 0.20), ranges, query);
		node.layout.visualKind = LayoutVisualKind.Custom;
		node.layout.intrinsicContent = resource.content;
		return node;
	}
}

private class SearchTextLayout {
	public final content:LayoutRenderableContent;
	final layout:TextLayout;
	final measurement:LayoutMeasuredContent;
	var value:String = "";
	var text:TextStyle;
	var paragraph:ParagraphStyle;
	var highlight:Color = Color.rgba(0, 0, 0, 0);
	var ranges:Array<{start:Int, end:Int}> = [];
	var signature:String = "";
	public function new(fonts:FontCollection) {
		text = new TextStyle(); paragraph = new ParagraphStyle();
		layout = TextLayout.create(fonts, "", 100000, text, paragraph);
		measurement = new LayoutMeasuredContent(function(constraints) {
			var width = Math.max(1, Math.min(100000, constraints.maxWidth));
			if (layout.width != width) layout.update(value, width, text, paragraph);
			var size = layout.measure();
			return new LayoutMeasureResult(Math.min(width, size.width), size.height);
		});
		content = new LayoutRenderableContent(measurement, function(canvas, _) {
			for (range in ranges) for (rect in layout.selectionRects(new TextPosition(range.start, 0), new TextPosition(range.end, 0)))
				canvas.fillRectIfPositive(rect, highlight);
			canvas.drawText(layout, 0, 0);
		});
	}
	public function update(value:String, text:TextStyle, paragraph:ParagraphStyle, foreground:Color,
		highlight:Color, ranges:Array<{start:Int, end:Int}>, query:String):Void {
		var next = haxe.Json.stringify([value, query, text.font, text.fontSize, text.letterSpacing,
			paragraph.wrap, paragraph.alignment, paragraph.lineHeight, paragraph.direction, paragraph.tabWidth,
			foreground.red, foreground.green, foreground.blue, foreground.alpha, highlight.red, highlight.green, highlight.blue]);
		if (next == signature) return;
		signature = next; this.value = value; this.text = text; this.paragraph = paragraph;
		this.highlight = highlight; this.ranges = ranges;
		layout.update(value, layout.width, text, paragraph); layout.setColor(foreground);
		measurement.invalidate(); content.invalidatePaint();
	}
	public function dispose():Void { content.dispose(); layout.dispose(); }
}
