package haxeon.ui.widgets.text;

import haxeon.ui.TextLayout.TextCaret;
import haxeon.ui.TextLayout.TextMetrics;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.TextLayout.TextRange;
import haxeon.ui.TextLayout.TextRangeRect;

import haxeon.ui.FontCollection;
import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.LayoutMeasureConstraints;
import haxeon.ui.LayoutMeasureResult;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.Rect;
import haxeon.ui.TextLayout;
import haxeon.ui.TextStyle;
import haxeon.ui.TextColorRange;
import haxeon.editor.TextDocument;

/** Retained layouts for bounded groups of paragraphs in one editor document. */
class TextEditorLayout {
	static inline var paragraphsPerLayout:Int = 64;
	static inline var maximumParagraphsPerLayout:Int = 128;
	/** Explicit code editing policy, independent of wrapping and syntax highlighting. */
	public var codeWordBoundaries:Bool = false;
	public var text(get, never):String;
	public var width(default, null):Float;
	/** Changes whenever edits or shaping constraints recompute paragraph geometry. */
	public var geometryRevision(default, null):Int = 0;
	public final textStyle:TextStyle;
	public final paragraphStyle:ParagraphStyle;
	public var paragraphCount(get, never):Int;
	/** Supplies sorted, disjoint absolute codepoint ranges for one visible chunk.
	 * Ranges may extend beyond the requested chunk and are clipped to it.
	 * The provider is queried at paint time, so text edits can refresh styles.
	 */
	public var colorRangeProvider:Null<(Int, Int)->Array<TextColorRange>>;
	public var decorationProvider:Null<(Int, Int)->Array<TextDecoration>>;

	final fonts:FontCollection;
	var paragraphs:Array<TextEditorParagraphRecord>;
	var rangeGeometryCache:Array<TextEditorRangeGeometryCache>;
	var offsets:TextDocument;
	var paragraphLineCount:Int;
	var contentWidth:Float;
	var contentHeight:Float;
	var firstBaseline:Float;
	var hasBaseline:Bool;
	var disposed:Bool;

	public function new(fonts:FontCollection, value:String, width:Float, textStyle:TextStyle,
			paragraphStyle:ParagraphStyle, ?offsetMap:TextDocument) {
		if (fonts == null || fonts.isDisposed())
			throw "Editor layout requires a live font collection";
		if (width <= 0.0 || textStyle == null || paragraphStyle == null)
			throw "Editor layout arguments are invalid";
		this.fonts = fonts;
		this.textStyle = copyTextStyle(textStyle);
		this.paragraphStyle = copyParagraphStyle(paragraphStyle);
		colorRangeProvider = null;
		decorationProvider = null;
		paragraphs = [];
		rangeGeometryCache = [];
		offsets = null;
		paragraphLineCount = 0;
		contentWidth = 0.0;
		contentHeight = 0.0;
		firstBaseline = 0.0;
		hasBaseline = false;
		disposed = false;
		if (offsetMap == null)
			update(value, width, this.textStyle, this.paragraphStyle);
		else
			updateDocument(offsetMap, width, this.textStyle, this.paragraphStyle);
	}

	function get_paragraphCount():Int
		return paragraphLineCount;

	function get_text():String
		return offsets == null ? "" : offsets.text;

	static function chunkCount(offsetMap:TextDocument):Int
		return Std.int((offsetMap.paragraphCount() + paragraphsPerLayout - 1) / paragraphsPerLayout);

	static function chunkRangeAt(offsetMap:TextDocument, index:Int):TextRange {
		var firstParagraph = index * paragraphsPerLayout;
		var lastParagraph = Std.int(Math.min(offsetMap.paragraphCount() - 1,
			firstParagraph + paragraphsPerLayout - 1));
		return new TextRange(offsetMap.paragraphRangeAtIndex(firstParagraph).start,
			offsetMap.paragraphRangeAtIndex(lastParagraph).end);
	}

	/** Updates only paragraph resources whose text or shaping inputs changed. */
	public function update(value:String, nextWidth:Float, nextTextStyle:TextStyle,
			nextParagraphStyle:ParagraphStyle, ?offsetMap:TextDocument):Void {
		ensureLive();
		if (nextWidth <= 0.0 || nextTextStyle == null || nextParagraphStyle == null)
			throw "Editor layout update arguments are invalid";
		var actualText = value == null ? "" : value;
		var nextOffsets = offsetMap == null ? new TextDocument(actualText) : offsetMap;
		if (nextOffsets.text != actualText)
			nextOffsets = new TextDocument(actualText);
		updateDocument(nextOffsets, nextWidth, nextTextStyle, nextParagraphStyle);
	}

	/** Updates retained paragraph layouts directly from the segmented document. */
	public function updateDocument(nextOffsets:TextDocument, nextWidth:Float,
			nextTextStyle:TextStyle, nextParagraphStyle:ParagraphStyle):Void {
		ensureLive();
		if (nextOffsets == null || nextWidth <= 0.0 || nextTextStyle == null || nextParagraphStyle == null)
			throw "Editor layout update arguments are invalid";
		var styleChanged = textStyle.font != nextTextStyle.font ||
			textStyle.fontSize != nextTextStyle.fontSize ||
			textStyle.letterSpacing != nextTextStyle.letterSpacing ||
			paragraphStyle.wrap != nextParagraphStyle.wrap ||
			paragraphStyle.alignment != nextParagraphStyle.alignment ||
			paragraphStyle.lineHeight != nextParagraphStyle.lineHeight ||
			paragraphStyle.direction != nextParagraphStyle.direction ||
			paragraphStyle.tabWidth != nextParagraphStyle.tabWidth;
		textStyle.font = nextTextStyle.font;
		textStyle.fontSize = nextTextStyle.fontSize;
		textStyle.letterSpacing = nextTextStyle.letterSpacing;
		paragraphStyle.wrap = nextParagraphStyle.wrap;
		paragraphStyle.alignment = nextParagraphStyle.alignment;
		paragraphStyle.lineHeight = nextParagraphStyle.lineHeight;
		paragraphStyle.direction = nextParagraphStyle.direction;
		paragraphStyle.tabWidth = nextParagraphStyle.tabWidth;

		var previous = paragraphs;
		var reusable = new Map<String, Array<TextEditorParagraphRecord>>();
		for (record in previous) {
			var records = reusable.get(record.text);
			if (records == null) {
				records = [];
				reusable.set(record.text, records);
			}
			records.push(record);
		}
		var used:Array<TextEditorParagraphRecord> = [];
		var next:Array<TextEditorParagraphRecord> = [];
		var nextCount = chunkCount(nextOffsets);
		for (index in 0...nextCount) {
			var range = chunkRangeAt(nextOffsets, index);
			var paragraphText = nextOffsets.sliceCodepoints(range.start, range.end);
			var previousRecord = index < previous.length ? previous[index] : null;
			var record:TextEditorParagraphRecord = null;
			if (previousRecord != null && !containsRecord(used, previousRecord) &&
				previousRecord.text == paragraphText &&
				previousRecord.layout.width == nextWidth && !styleChanged) {
				record = previousRecord;
			} else if (!styleChanged) {
				var matching = reusable.get(paragraphText);
				if (matching != null)
					while (matching.length > 0 && record == null) {
						var candidate:TextEditorParagraphRecord = matching.pop();
						if (candidate != null && candidate.layout.width == nextWidth &&
							!containsRecord(used, candidate))
							record = candidate;
					}
			}
			if (record == null && previousRecord != null && !containsRecord(used, previousRecord))
				record = previousRecord;
			if (record != null) {
				var textChanged = record.text != paragraphText;
				if (textChanged || record.layout.width != nextWidth || styleChanged) {
					record.layout.update(paragraphText, nextWidth, textStyle, paragraphStyle);
					record.renderRanges = null;
					record.text = paragraphText;
				}
			} else {
				record = new TextEditorParagraphRecord(paragraphText,
					TextLayout.create(fonts, paragraphText, nextWidth, textStyle, paragraphStyle));
			}
			used.push(record);
			record.start = range.start;
			record.end = range.end;
			record.y = 0.0;
			record.height = 0.0;
			next.push(record);
		}
		for (record in previous)
			if (!containsRecord(used, record))
				record.layout.dispose();

		width = nextWidth;
		offsets = nextOffsets;
		paragraphLineCount = nextOffsets.paragraphCount();
		clearRangeGeometryCache();
		paragraphs = next;
		recomputeMetrics();
	}

	public function setText(value:String, ?offsetMap:TextDocument):Void
		update(value, width, textStyle, paragraphStyle, offsetMap);

	/** Updates the affected chunk window while preserving all other boundaries.
	 * Chunks grow locally to the hard paragraph bound before being split.
	 */
	public function setTextAfterEdit(nextOffsets:TextDocument,
			oldStart:Int, oldEnd:Int, newStart:Int, newEnd:Int,
			oldDocumentLength:Int):Void {
		ensureLive();
		if (nextOffsets == null)
			throw "Editor layout update requires a document";
		if (paragraphs.length == 0) {
			updateDocument(nextOffsets, width, textStyle, paragraphStyle);
			return;
		}
		var previous = paragraphs;
		var first = paragraphIndexAtOffsetIn(previous, oldStart, oldDocumentLength);
		var last = paragraphIndexAtOffsetIn(previous, oldEnd, oldDocumentLength);
		var delta = nextOffsets.codepointCount - oldDocumentLength;
		var firstOffset = previous[first].start;
		var lastOffset = clamp(previous[last].end + delta, firstOffset,
			nextOffsets.codepointCount);
		var firstParagraph = nextOffsets.paragraphIndexAtOffset(firstOffset);
		var lastParagraph = nextOffsets.paragraphIndexAtOffset(lastOffset);
		var result:Array<TextEditorParagraphRecord> = [];
		for (index in 0...first)
			result.push(previous[index]);
		var used:Array<TextEditorParagraphRecord> = [];
		var paragraph = firstParagraph;
		while (paragraph <= lastParagraph) {
			var remaining = lastParagraph - paragraph + 1;
			var chunksRemaining = remaining <= maximumParagraphsPerLayout ? 1 :
				Std.int((remaining + paragraphsPerLayout - 1) / paragraphsPerLayout);
			var chunkSize = Std.int((remaining + chunksRemaining - 1) / chunksRemaining);
			var paragraphEnd = paragraph + chunkSize - 1;
			var chunkStart = paragraph == firstParagraph ? firstOffset :
				nextOffsets.paragraphRangeAtIndex(paragraph).start;
			var chunkEnd = paragraphEnd == lastParagraph ? lastOffset :
				nextOffsets.paragraphRangeAtIndex(paragraphEnd).end;
			var chunkText = nextOffsets.sliceCodepoints(chunkStart, chunkEnd);
			var record:TextEditorParagraphRecord = null;
			for (index in first...(last + 1)) {
				var candidate = previous[index];
				if (!containsRecord(used, candidate) && candidate.text == chunkText) {
					record = candidate;
					break;
				}
			}
			if (record == null)
				for (index in first...(last + 1)) {
					var candidate = previous[index];
					if (!containsRecord(used, candidate)) {
						record = candidate;
						break;
					}
				}
			if (record == null)
				record = new TextEditorParagraphRecord(chunkText,
					TextLayout.create(fonts, chunkText, width, textStyle, paragraphStyle));
			else if (record.text != chunkText) {
				// Keep only source-mapped prefix/suffix portions. Repartitioned
				// boundaries may change both ends of a chunk, so the middle
				// replacement includes any newly assigned neighboring text.
				var prefix = record.start == chunkStart ?
					clamp(Std.int(Math.min(oldStart, newStart)) - chunkStart, 0,
						Std.int(Math.min(record.end - record.start, chunkEnd - chunkStart))) : 0;
				var suffix = record.end + delta == chunkEnd ?
					Std.int(Math.min(record.end - Math.max(oldEnd, record.start),
						chunkEnd - Math.max(newEnd, chunkStart))) : 0;
				suffix = clamp(suffix, 0, Std.int(Math.min(record.end - record.start - prefix,
					chunkEnd - chunkStart - prefix)));
				record.layout.edit(prefix, record.end - record.start - suffix,
					nextOffsets.sliceCodepoints(chunkStart + prefix, chunkEnd - suffix), chunkText);
				record.renderRanges = null;
				record.text = chunkText;
			}
			used.push(record);
			record.start = chunkStart;
			record.end = chunkEnd;
			result.push(record);
			paragraph = paragraphEnd + 1;
		}
		for (index in first...(last + 1)) {
			var record = previous[index];
			if (!containsRecord(used, record))
				record.layout.dispose();
		}
		for (index in last + 1...previous.length) {
			var record = previous[index];
			record.start += delta;
			record.end += delta;
			result.push(record);
		}
		offsets = nextOffsets;
		paragraphLineCount = nextOffsets.paragraphCount();
		clearRangeGeometryCache();
		paragraphs = result;
		recomputeMetrics();
	}

	public function measure():TextMetrics
		return new TextMetrics(0.0, 0.0, contentWidth, contentHeight);

	/** First visual caret of a logical paragraph, using retained shaping geometry. */
	public function paragraphCaret(index:Int):TextCaret {
		ensureLive();
		if (index < 0 || index >= paragraphLineCount) throw "Paragraph index out of bounds";
		return caret(new TextPosition(offsets.paragraphRangeAtIndex(index).start, 0));
	}

	/** Resolved visual rows, including wrapped continuations and the final empty row.
	 * Offsets are absolute codepoints; vertical bounds are in document coordinates.
	 */
	public function visualRows():Array<{start:Int, end:Int, top:Float, bottom:Float}> {
		ensureLive();
		var rows:Array<{start:Int, end:Int, top:Float, bottom:Float}> = [];
		for (record in paragraphs) {
			for (rect in record.layout.lineRects(0, record.end - record.start, -1.0e30, 1.0e30)) {
				var hit = record.layout.hitTest(rect.x + rect.width / 2, rect.y + rect.height / 2);
				var range = record.layout.lineRangeAt(hit.offset);
				rows.push({start: record.start + range.start, end: record.start + range.end,
					top: record.y + rect.y, bottom: record.y + rect.y + rect.height});
			}
			var last = record.layout.caret(new TextPosition(record.end - record.start, 0));
			var top = record.y + last.y + Math.min(last.ascender, last.descender);
			var bottom = record.y + last.y + Math.max(last.ascender, last.descender);
			if (rows.length == 0 || top >= rows[rows.length - 1].bottom - 0.01)
				rows.push({start: record.end, end: record.end, top: top, bottom: bottom});
		}
		for (index in 0...rows.length - 1)
			rows[index].end = Std.int(Math.min(rows[index].end, rows[index + 1].start));
		return rows;
	}

	/** Logical paragraph containing a vertical position in the shaped document. */
	public function paragraphIndexAtY(y:Float):Int {
		ensureLive();
		return offsets.paragraphIndexAtOffset(hitTest(0.0, y).offset);
	}

	/** Measures this retained content against the constraints of a Custom node. */
	public function measureForConstraints(constraints:LayoutMeasureConstraints):LayoutMeasureResult {
		ensureLive();
		if (constraints == null || constraints.maxWidth < constraints.minWidth ||
			constraints.maxHeight < constraints.minHeight)
			throw "Editor layout constraints are invalid";
		var measured = measure();
		var measuredWidth = Math.max(measured.width, constraints.minWidth);
		if (Math.isFinite(constraints.maxWidth))
			measuredWidth = Math.min(measuredWidth, constraints.maxWidth);
		var measuredHeight = Math.max(measured.height, constraints.minHeight);
		if (Math.isFinite(constraints.maxHeight))
			measuredHeight = Math.min(measuredHeight, constraints.maxHeight);
		var baseline = firstBaseline;
		var measuredHasBaseline = hasBaseline && Math.isFinite(baseline) && baseline >= 0.0 &&
			baseline <= measuredHeight;
		if (!measuredHasBaseline && paragraphs.length > 0 && paragraphs[0].height > 0.0) {
			var firstCaret = paragraphs[0].layout.caret(new TextPosition(0, 0));
			baseline = firstCaret.y;
			measuredHasBaseline = Math.isFinite(baseline) && baseline >= 0.0 && baseline <= measuredHeight;
		}
		return new LayoutMeasureResult(measuredWidth, measuredHeight, baseline, measuredHasBaseline);
	}

	/** Whitespace is a paint-only decoration; source offsets and shaping stay unchanged. */
	public function paintWhitespace(canvas:Canvas, mode:String, selections:Array<TextSelection>,
			color:Color, selectedColor:Color, minY:Float, maxY:Float, minX:Float, maxX:Float):Void {
		if (mode == "off") return;
		var ranges = [for (selection in selections) if (selection.anchor != selection.focus)
			{start: Std.int(Math.min(selection.anchor, selection.focus)), end: Std.int(Math.max(selection.anchor, selection.focus))}];
		ranges.sort((a, b) -> a.start - b.start);
		var merged:Array<{start:Int, end:Int}> = [];
		for (range in ranges) {
			if (merged.length > 0 && merged[merged.length - 1].end >= range.start)
				merged[merged.length - 1].end = Std.int(Math.max(merged[merged.length - 1].end, range.end));
			else merged.push(range);
		}
		if (mode != "all" && merged.length == 0) return;
		var dots = [new haxeon.ui.PathBuilder(), new haxeon.ui.PathBuilder()];
		var arrows = [new haxeon.ui.PathBuilder(), new haxeon.ui.PathBuilder()];
		var dotCounts = [0, 0], arrowCounts = [0, 0];
		var rangeIndex = 0;
		var low = 0, high = paragraphs.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (paragraphs[middle].y + paragraphs[middle].height <= minY) low = middle + 1;
			else high = middle;
		}
		for (index in low...paragraphs.length) {
			var record = paragraphs[index];
			if (record.y >= maxY) break;
			var visibleTop = Math.max(0, minY - record.y);
			var visibleBottom = Math.min(record.height, maxY - record.y);
			var a = record.layout.hitTest(0, visibleTop).offset;
			var b = record.layout.hitTest(record.layout.width, visibleTop).offset;
			var c = record.layout.hitTest(0, Math.max(visibleTop, visibleBottom - 0.01)).offset;
			var d = record.layout.hitTest(record.layout.width, Math.max(visibleTop, visibleBottom - 0.01)).offset;
			var first = Math.max(0, Math.min(Math.min(a, b), Math.min(c, d)) - 2);
			var last = Math.min(record.end - record.start, Math.max(Math.max(a, b), Math.max(c, d)) + 2);
			for (token in record.whitespaceTokens()) {
				if (token.end <= first) continue;
				if (token.start >= last) break;
				// Ordinary selections expose indentation without adding line-ending glyphs.
				if (token.kind == 2 && mode != "all") continue;
				var absolute = record.start + token.start;
				while (rangeIndex < merged.length && merged[rangeIndex].end <= absolute) rangeIndex++;
				var selected = rangeIndex < merged.length && merged[rangeIndex].start < record.start + token.end;
				if (mode != "all" && !selected) continue;
				var caret = record.layout.caret(new TextPosition(token.start, 0));
				var top = record.y + caret.y + Math.min(caret.ascender, caret.descender);
				var height = Math.abs(caret.descender - caret.ascender);
				var left = caret.x, right = caret.x;
				if (token.kind == 2) {
					var rects = record.layout.selectionRects(new TextPosition(token.start, 0), new TextPosition(token.end, 0));
					if (rects.length == 0) continue;
					left = rects[0].x;
					right = left + Math.max(7, textStyle.fontSize * 0.6);
				} else {
					var endCaret = record.layout.caret(new TextPosition(token.end, 0));
					left = Math.min(caret.x, endCaret.x); right = Math.max(caret.x, endCaret.x);
				}
				if (top + height <= minY || top >= maxY || right < minX || left > maxX) continue;
				var target = selected ? 1 : 0;
				var y = top + height * 0.55;
				if (token.kind == 0) {
					var diameter = Math.max(1.2, textStyle.fontSize * 0.1);
					dots[target].roundRect((left + right - diameter) / 2, y - diameter / 2, diameter, diameter, diameter / 2);
					dotCounts[target]++;
				} else {
					var padding = token.kind == 2 ? 0.0 : Math.min(2, (right - left) * 0.15);
					var from = left + padding, to = right - padding;
					if (token.kind == 1) {
						// A tab's geometry owns its full advance; the symbol remains compact.
						var markerWidth = Math.min(to - from, textStyle.fontSize * 0.5);
						var center = (left + right) / 2;
						from = center - markerWidth / 2;
						to = center + markerWidth / 2;
					}
					var size = Math.min(textStyle.fontSize * (token.kind == 2 ? 0.2 : 0.14), (to - from) * 0.3);
					if (size <= 0) continue;
					var path = arrows[target];
					if (token.kind == 2) {
						path.moveTo(to, y - textStyle.fontSize * 0.4).lineTo(to, y).lineTo(from, y);
						path.moveTo(from + size, y - size).lineTo(from, y).lineTo(from + size, y + size);
					} else {
						path.moveTo(from, y).lineTo(to, y);
						path.moveTo(to - size, y - size).lineTo(to, y).lineTo(to - size, y + size);
					}
					arrowCounts[target]++;
				}
			}
		}
		for (index in 0...2) {
			var ink = index == 1 ? selectedColor : color;
			if (dotCounts[index] > 0) canvas.fillTransient(dots[index].build(), ink);
			if (arrowCounts[index] > 0) canvas.strokeTransient(arrows[index].build(), ink, Math.max(0.7, textStyle.fontSize / 18));
		}
	}

	/** Paints retained paragraphs intersecting the visible document range. */
	public function paint(canvas:Canvas, color:Color, minY:Float = 0.0,
			maxY:Float = 1.0e30, minX:Float = 0.0, maxX:Float = 1.0e30,
			includeBackground:Bool = true):Void {
		ensureLive();
		if (canvas == null || color == null)
			throw "Editor layout paint arguments are invalid";
		if (includeBackground)
			paintDecorations(canvas, true, minY, maxY, minX, maxX);
		var low = 0;
		var high = paragraphs.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			var candidate = paragraphs[middle];
			if (candidate.y + candidate.height <= minY)
				low = middle + 1;
			else
				high = middle;
		}
		for (index in low...paragraphs.length) {
			var record = paragraphs[index];
			if (record.y >= maxY)
				break;
			if (record.text.length > 0) {
				var previous = record.renderColor;
				if (previous == null || previous.red != color.red ||
					previous.green != color.green || previous.blue != color.blue ||
					previous.alpha != color.alpha) {
					record.layout.setColor(color);
					record.renderColor = color;
				}
				applyForegroundRanges(record);
				canvas.drawText(record.layout, 0.0, record.y);
			}
		}
		paintDecorations(canvas, false, minY, maxY, minX, maxX);
	}

	/** Paints one decoration layer using cached measured range geometry. */
	public function paintDecorations(canvas:Canvas, behindText:Bool, minY:Float, maxY:Float,
			minX:Float, maxX:Float):Void {
		ensureLive();
		// Keep one provider for this layer even if a callback replaces the widget's provider.
		var provider = decorationProvider;
		if (provider == null)
			return;
		var low = 0;
		var high = paragraphs.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			var candidate = paragraphs[middle];
			if (candidate.y + candidate.height <= minY)
				low = middle + 1;
			else
				high = middle;
		}
		for (index in low...paragraphs.length) {
			var record = paragraphs[index];
			if (record.y + record.height <= minY)
				continue;
			if (record.y >= maxY)
				break;
			var values = provider(record.start, record.end);
			if (values == null)
				throw "Text decoration provider returned null";
			for (value in values) {
				if (value == null || value.end > offsets.codepointCount)
					throw "Text decoration is outside the document";
				var isBackground = value.kind == Background || value.kind == WholeLineBackground;
				if (isBackground != behindText)
					continue;
				if (value.start == value.end) {
					if (value.start < record.start || value.start > record.end ||
						(value.start == record.end && record.end < offsets.codepointCount))
						continue;
				} else if (value.end <= record.start || value.start >= record.end)
					continue;
				var rects = value.rectangles(this, Math.max(minY, record.y),
					Math.min(maxY, record.y + record.height));
				value.paint(canvas, rects, minX, maxX);
			}
		}
	}

	/** Whole-line decoration geometry from indexed visual rows in the viewport. */
	public function wholeLineRects(start:Int, end:Int, minY:Float, maxY:Float):Array<Rect> {
		ensureLive();
		if (start < 0 || end < start || end > offsets.codepointCount || maxY < minY)
			throw "Whole-line range is outside the document";
		var result:Array<Rect> = [];
		var low = 0;
		var high = paragraphs.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (paragraphs[middle].y + paragraphs[middle].height <= minY)
				low = middle + 1;
			else
				high = middle;
		}
		for (index in low...paragraphs.length) {
			var record = paragraphs[index];
			if (record.y >= maxY)
				break;
			if (record.y + record.height <= minY || record.end <= start || record.start >= end)
				continue;
			var localStart = Std.int(Math.max(start, record.start)) - record.start;
			var localEnd = Std.int(Math.min(end, record.end)) - record.start;
			for (rect in record.layout.lineRects(localStart, localEnd,
				minY - record.y, maxY - record.y))
				result.push(new Rect(0.0, record.y + rect.y, width, rect.height));
		}
		return result;
	}

	function applyForegroundRanges(record:TextEditorParagraphRecord):Void {
		var ranges:Array<TextColorRange> = [];
		if (colorRangeProvider != null) {
			var supplied = colorRangeProvider(record.start, record.end);
			if (supplied == null)
				throw "Text foreground provider returned null";
			var previousEnd = 0;
			for (range in supplied) {
				if (range == null || range.start < previousEnd)
					throw "Text foreground ranges must be sorted and disjoint";
				previousEnd = range.end;
				var start = Std.int(Math.max(range.start, record.start));
				var end = Std.int(Math.min(range.end, record.end));
				if (start < end)
					ranges.push(new TextColorRange(start - record.start, end - record.start, range.color));
			}
		}
		var previous = record.renderRanges;
		var changed = previous == null || previous.length != ranges.length;
		if (!changed && previous != null)
			for (index in 0...ranges.length) {
				var before = previous[index];
				var after = ranges[index];
				if (before.start != after.start || before.end != after.end ||
					before.color.red != after.color.red || before.color.green != after.color.green ||
					before.color.blue != after.color.blue || before.color.alpha != after.color.alpha)
					changed = true;
			}
		if (changed) {
			record.layout.setColorRanges(ranges);
			record.renderRanges = ranges;
		}
	}

	public function hitTest(x:Float, y:Float):TextPosition {
		ensureLive();
		if (paragraphs.length == 0)
			return new TextPosition(0, 0);
		// Blank space below the document selects its end, independently of
		// horizontal position. Within the last line, retain normal hit testing.
		if (y >= contentHeight)
			return new TextPosition(offsets.codepointCount, 0);
		var record = paragraphAtY(y);
		var hit = record.layout.hitTest(x, y - record.y);
		return new TextPosition(clamp(hit.offset + record.start, record.start, record.end), hit.affinity);
	}

	public function offsetFromPosition(position:TextPosition):Int {
		ensureLive();
		if (position == null)
			throw "Text position cannot be null";
		var record = paragraphAtOffset(position.offset);
		return clamp(record.layout.offsetFromPosition(
			new TextPosition(clamp(position.offset - record.start, 0, record.end - record.start),
				position.affinity)) + record.start, record.start, record.end);
	}

	public function caret(position:TextPosition):TextCaret {
		ensureLive();
		if (position == null)
			throw "Text position cannot be null";
		var record = paragraphAtOffset(position.offset);
		var local = clamp(position.offset - record.start, 0, record.end - record.start);
		var value = record.layout.caret(new TextPosition(local, position.affinity));
		return new TextCaret(value.x, value.y + record.y, value.ascender, value.descender,
			value.slope, value.direction);
	}

	public function selectionRects(start:TextPosition, end:TextPosition,
			minY:Float = -1.0e30, maxY:Float = 1.0e30):Array<Rect> {
		ensureLive();
		if (start == null || end == null)
			throw "Text selection endpoints cannot be null";
		if (!Math.isFinite(minY) || !Math.isFinite(maxY) || maxY < minY)
			throw "Text selection geometry bounds are invalid";
		// Hits identify glyph edges, not necessarily logical insertion offsets.
		// Order the resolved offsets while keeping each affinity with its glyph.
		var startOffset = offsetFromPosition(start), endOffset = offsetFromPosition(end);
		var forward = startOffset <= endOffset;
		var firstPosition = forward ? start : end;
		var lastPosition = forward ? end : start;
		var first = forward ? startOffset : endOffset;
		var last = forward ? endOffset : startOffset;
		if (first == last)
			return [];
		var result:Array<Rect> = [];
		var low = 0;
		var high = paragraphs.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (paragraphs[middle].y + paragraphs[middle].height <= minY)
				low = middle + 1;
			else
				high = middle;
		}
		for (index in low...paragraphs.length) {
			var record = paragraphs[index];
			if (record.y >= maxY) break;
			var localStart:Int = first > record.start ? first : record.start;
			var localEnd:Int = last < record.end ? last : record.end;
			if (localEnd <= localStart)
				continue;
			// Interior paragraphs use canonical insertion edges. Only the paragraph
			// containing an original endpoint may interpret that endpoint's affinity.
			var useFirstPosition = localStart == first && firstPosition.offset >= record.start &&
				firstPosition.offset < record.end;
			var useLastPosition = localEnd == last && lastPosition.offset >= record.start &&
				lastPosition.offset <= record.end;
			for (rect in record.layout.selectionRects(
				new TextPosition((useFirstPosition ? firstPosition.offset : localStart) - record.start,
					useFirstPosition ? firstPosition.affinity : 0),
				new TextPosition((useLastPosition ? lastPosition.offset : localEnd) - record.start,
					useLastPosition ? lastPosition.affinity : 0)))
				if (rect.y + record.y < maxY && rect.y + record.y + rect.height > minY)
					result.push(new Rect(rect.x, rect.y + record.y, rect.width, rect.height));
		}
		return result;
	}

	/** Returns shaped grapheme rectangles paired with absolute document ranges. */
	public function selectionRangeRects(start:TextPosition, end:TextPosition,
			minY:Float = -1.0e30, maxY:Float = 1.0e30):Array<TextRangeRect> {
		ensureLive();
		if (start == null || end == null)
			throw "Text selection endpoints cannot be null";
		if (!Math.isFinite(minY) || !Math.isFinite(maxY) || maxY < minY)
			throw "Text selection geometry bounds are invalid";
		var startOffset = offsetFromPosition(start), endOffset = offsetFromPosition(end);
		var forward = startOffset <= endOffset;
		var firstPosition = forward ? start : end;
		var lastPosition = forward ? end : start;
		var first = clamp(forward ? startOffset : endOffset, 0, offsets.codepointCount);
		var last = clamp(forward ? endOffset : startOffset, 0, offsets.codepointCount);
		var firstAffinity = firstPosition.affinity;
		var lastAffinity = lastPosition.affinity;
		if (first == last)
			return [];
		for (entry in rangeGeometryCache)
			if (entry.start == firstPosition.offset && entry.end == lastPosition.offset &&
				entry.startAffinity == firstAffinity && entry.endAffinity == lastAffinity &&
				entry.minY == minY && entry.maxY == maxY)
				return entry.rectangles.copy();
		var result:Array<TextRangeRect> = [];
		var low = 0;
		var high = paragraphs.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (paragraphs[middle].y + paragraphs[middle].height <= minY)
				low = middle + 1;
			else
				high = middle;
		}
		for (index in low...paragraphs.length) {
			var record = paragraphs[index];
			if (record.y >= maxY)
				break;
			var localStart = first > record.start ? first : record.start;
			var localEnd = last < record.end ? last : record.end;
			if (localEnd <= localStart)
				continue;
			if (minY > record.y || maxY < record.y + record.height) {
				var visibleTop = Math.max(0.0, minY - record.y);
				var visibleBottom = Math.min(record.height, maxY - record.y);
				if (visibleBottom <= visibleTop)
					continue;
				var sampleTop = Math.min(visibleBottom, visibleTop + 1.0);
				var sampleBottom = Math.max(visibleTop, visibleBottom - 1.0);
				var topLeft = record.layout.hitTest(0.0, sampleTop).offset;
				var topRight = record.layout.hitTest(record.layout.width, sampleTop).offset;
				var bottomLeft = record.layout.hitTest(0.0, sampleBottom).offset;
				var bottomRight = record.layout.hitTest(record.layout.width, sampleBottom).offset;
				var visibleStart = clamp(Std.int(Math.min(Math.min(topLeft, topRight),
					Math.min(bottomLeft, bottomRight))), 0, record.end - record.start);
				var visibleEnd = clamp(Std.int(Math.max(Math.max(topLeft, topRight),
					Math.max(bottomLeft, bottomRight))), 0, record.end - record.start);
				for (_ in 0...2) {
					if (visibleStart > 0)
						visibleStart = record.layout.previousGrapheme(visibleStart);
					if (visibleEnd < record.end - record.start)
						visibleEnd = record.layout.nextGrapheme(visibleEnd);
				}
				var clippedStart = record.start + visibleStart;
				var clippedEnd = record.start + visibleEnd;
				if (localStart < clippedStart)
					localStart = clippedStart;
				if (localEnd > clippedEnd)
					localEnd = clippedEnd;
			}
			if (localEnd <= localStart)
				continue;
			// An affinity endpoint can belong to the preceding chunk while its logical
			// insertion offset starts this one. Use this chunk's canonical edge then.
			var useFirstPosition = localStart == first && firstPosition.offset >= record.start &&
				firstPosition.offset < record.end;
			var useLastPosition = localEnd == last && lastPosition.offset >= record.start &&
				lastPosition.offset <= record.end;
			for (rect in record.layout.selectionRangeRects(
				new TextPosition((useFirstPosition ? firstPosition.offset : localStart) - record.start,
					useFirstPosition ? firstAffinity : 0),
				new TextPosition((useLastPosition ? lastPosition.offset : localEnd) - record.start,
					useLastPosition ? lastAffinity : 0)))
				result.push(new TextRangeRect(rect.start + record.start, rect.end + record.start,
					rect.x, rect.y + record.y, rect.width, rect.height, rect.visualLeftIsStart));
		}
		rangeGeometryCache.push(new TextEditorRangeGeometryCache(firstPosition.offset, lastPosition.offset, firstAffinity,
			lastAffinity, minY, maxY, result.copy()));
		if (rangeGeometryCache.length > 2)
			rangeGeometryCache.shift();
		return result;
	}

	public function nextGrapheme(offset:Int):Int {
		ensureLive();
		var recordIndex = paragraphIndexAtOffset(offset);
		var record = paragraphs[recordIndex];
		var local = clamp(offset - record.start, 0, record.end - record.start);
		var next = record.layout.nextGrapheme(local);
		if (next == local && local >= record.end - record.start && recordIndex + 1 < paragraphs.length)
			return paragraphs[recordIndex + 1].start;
		return clamp(record.start + next, record.start, record.end);
	}

	public function previousGrapheme(offset:Int):Int {
		ensureLive();
		var recordIndex = paragraphIndexAtOffset(offset);
		var record = paragraphs[recordIndex];
		var local = clamp(offset - record.start, 0, record.end - record.start);
		var previous = record.layout.previousGrapheme(local);
		if (previous == local && local == 0 && recordIndex > 0)
			return paragraphs[recordIndex - 1].end;
		return clamp(record.start + previous, record.start, record.end);
	}

	public function alignGrapheme(offset:Int):Int {
		ensureLive();
		var record = paragraphAtOffset(offset);
		var local = clamp(offset - record.start, 0, record.end - record.start);
		return clamp(record.start + record.layout.alignGrapheme(local), record.start, record.end);
	}

	public function wordRange(position:TextPosition):Array<Int> {
		ensureLive();
		var record = paragraphAtOffset(position.offset);
		var local = clamp(position.offset - record.start, 0, record.end - record.start);
		record.layout.setCodeWordBoundaries(codeWordBoundaries);
		var range = record.layout.wordRange(new TextPosition(local, position.affinity));
		return [record.start + range[0], record.start + range[1]];
	}

	public function wordRangeAt(offset:Int):TextRange {
		ensureLive();
		var record = paragraphAtOffset(offset);
		var local = clamp(offset - record.start, 0, record.end - record.start);
		record.layout.setCodeWordBoundaries(codeWordBoundaries);
		var range = record.layout.wordRangeAt(local);
		return new TextRange(record.start + range.start, record.start + range.end);
	}

	public function lineRangeAt(offset:Int):TextRange {
		ensureLive();
		var record = paragraphAtOffset(offset);
		var local = clamp(offset - record.start, 0, record.end - record.start);
		var range = record.layout.lineRangeAt(local);
		var end = record.start + range.end;
		if (end == record.end && end < offsets.codepointCount)
			end++;
		return new TextRange(record.start + range.start, end);
	}

	public function moveWord(offset:Int, direction:Int, macStyle:Bool = false):Int {
		ensureLive();
		if (direction != -1 && direction != 1)
			throw "Text word movement arguments are invalid";
		var recordIndex = paragraphIndexAtOffset(offset);
		var record = paragraphs[recordIndex];
		var local = clamp(offset - record.start, 0, record.end - record.start);
		record.layout.setCodeWordBoundaries(codeWordBoundaries);
		var moved = record.layout.moveWord(local, direction, macStyle);
		if (moved == local && local >= record.end - record.start && direction > 0 &&
			recordIndex + 1 < paragraphs.length)
			return paragraphs[recordIndex + 1].start;
		if (moved == local && local == 0 && direction < 0 && recordIndex > 0)
			return paragraphs[recordIndex - 1].end;
		return clamp(record.start + moved, record.start, record.end);
	}

	public function moveParagraph(offset:Int, direction:Int, macStyle:Bool = false):Int {
		ensureLive();
		if (direction != -1 && direction != 1)
			throw "Text paragraph movement arguments are invalid";
		var recordIndex = paragraphIndexAtOffset(offset);
		var record = paragraphs[recordIndex];
		var local = clamp(offset - record.start, 0, record.end - record.start);
		var moved = record.layout.moveParagraph(local, direction, macStyle);
		if (moved != local)
			return clamp(record.start + moved, record.start, record.end);
		if (direction < 0 && local == 0 && recordIndex > 0) {
			var previousParagraph = offsets.paragraphIndexAtOffset(record.start) - 1;
			return offsets.paragraphRangeAtIndex(previousParagraph).start;
		}
		if (direction > 0 && local == record.end - record.start &&
			recordIndex + 1 < paragraphs.length)
			return paragraphs[recordIndex + 1].start;
		return clamp(record.start + moved, record.start, record.end);
	}

	public function isDisposed():Bool return disposed;

	public function dispose():Void {
		if (disposed)
			return;
		for (record in paragraphs)
			record.layout.dispose();
		clearRangeGeometryCache();
		paragraphs = [];
		disposed = true;
	}

	function recomputeMetrics():Void {
		geometryRevision++;
		contentWidth = 0.0;
		contentHeight = 0.0;
		firstBaseline = 0.0;
		hasBaseline = false;
		for (record in paragraphs) {
			record.y = contentHeight;
			var metrics = record.layout.measure();
			var lineHeight = paragraphStyle.lineHeight == null ? 0.0 : paragraphStyle.lineHeight;
			if (lineHeight <= 0.0) {
				var caret = record.layout.caret(new TextPosition(0, 0));
				lineHeight = Math.abs(caret.descender - caret.ascender);
			}
			record.height = Math.max(metrics.height, Math.max(1.0, lineHeight));
			contentWidth = Math.max(contentWidth, metrics.width);
			if (!hasBaseline) {
				firstBaseline = record.y + record.layout.caret(new TextPosition(0, 0)).y;
				hasBaseline = Math.isFinite(firstBaseline) && firstBaseline >= 0.0;
			}
			contentHeight += record.height;
		}
	}

	function paragraphAtY(y:Float):TextEditorParagraphRecord {
		if (y <= 0.0)
			return paragraphs[0];
		for (record in paragraphs)
			if (y < record.y + record.height)
				return record;
		return paragraphs[paragraphs.length - 1];
	}

	function paragraphAtOffset(offset:Int):TextEditorParagraphRecord
		return paragraphs[paragraphIndexAtOffset(offset)];

	function paragraphIndexAtOffset(offset:Int):Int {
		return paragraphIndexAtOffsetIn(paragraphs, offset, offsets.codepointCount);
	}

	static function paragraphIndexAtOffsetIn(records:Array<TextEditorParagraphRecord>,
			offset:Int, documentLength:Int):Int {
		var value = clamp(offset, 0, documentLength);
		var low = 0;
		var high = records.length - 1;
		var result = high;
		while (low <= high) {
			var middle = (low + high) >> 1;
			var record = records[middle];
			if (value < record.start)
				high = middle - 1;
			else if (value > record.end)
				low = middle + 1;
			else
				return middle;
		}
		return clamp(low, 0, records.length - 1);
	}

	function ensureLive():Void {
		if (disposed)
			throw "Editor layout has been disposed";
	}

	function clearRangeGeometryCache():Void
		rangeGeometryCache = [];

	static function containsRecord(records:Array<TextEditorParagraphRecord>,
			value:TextEditorParagraphRecord):Bool {
		for (record in records)
			if (record == value)
				return true;
		return false;
	}

	static function copyTextStyle(style:TextStyle):TextStyle
		return new TextStyle(style.fontSize, style.font, style.letterSpacing);

	static function copyParagraphStyle(style:ParagraphStyle):ParagraphStyle
		return new ParagraphStyle(style.wrap, style.alignment, style.lineHeight, style.direction, style.tabWidth);

	static inline function clamp(value:Int, low:Int, high:Int):Int
		return value < low ? low : (value > high ? high : value);
}

class TextEditorParagraphRecord {
	public var start:Int;
	public var end:Int;
	public var text:String;
	public var y:Float;
	public var height:Float;
	public var renderColor:Null<Color>;
	public var renderRanges:Null<Array<TextColorRange>>;
	public final layout:TextLayout;
	var whitespaceText:Null<String>;
	var whitespace:Array<{start:Int, end:Int, kind:Int}> = [];

	public function whitespaceTokens():Array<{start:Int, end:Int, kind:Int}> {
		if (whitespaceText == text) return whitespace;
		whitespaceText = text;
		whitespace = [];
		var unit = 0, point = 0;
		while (unit < text.length) {
			var code = text.charCodeAt(unit);
			var units = code >= 0xd800 && code <= 0xdbff && unit + 1 < text.length &&
				text.charCodeAt(unit + 1) >= 0xdc00 && text.charCodeAt(unit + 1) <= 0xdfff ? 2 : 1;
			var count = 1;
			var kind = code == 32 ? 0 : code == 9 ? 1 :
				(code == 10 || code == 13 || code == 0x85 || code == 0x2028 || code == 0x2029) ? 2 : -1;
			if (code == 13 && unit + 1 < text.length && text.charCodeAt(unit + 1) == 10) { units = 2; count = 2; }
			if (kind >= 0) whitespace.push({start: point, end: point + count, kind: kind});
			unit += units; point += count;
		}
		return whitespace;
	}


	public function new(text:String, layout:TextLayout) {
		this.text = text;
		this.layout = layout;
		start = 0;
		end = 0;
		y = 0.0;
		height = 0.0;
		renderColor = null;
		renderRanges = null;
	}
}

/** Cached selection geometry for one active editor range and viewport. */
class TextEditorRangeGeometryCache {
	public final start:Int;
	public final end:Int;
	public final startAffinity:Int;
	public final endAffinity:Int;
	public final minY:Float;
	public final maxY:Float;
	public final rectangles:Array<TextRangeRect>;

	public function new(start:Int, end:Int, startAffinity:Int, endAffinity:Int,
			minY:Float, maxY:Float, rectangles:Array<TextRangeRect>) {
		this.start = start;
		this.end = end;
		this.startAffinity = startAffinity;
		this.endAffinity = endAffinity;
		this.minY = minY;
		this.maxY = maxY;
		this.rectangles = rectangles;
	}
}
