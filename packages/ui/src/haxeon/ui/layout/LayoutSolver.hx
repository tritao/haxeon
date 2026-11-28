package haxeon.ui.layout;

import haxe.io.Bytes;
import haxeon.ui.IntIndex;
import haxeon.ui.LayoutAnchor;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutContent;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;

/**
 * Lays a `LayoutNode` tree out (ADR 0009). Each axis is solved in two passes: fit sizes go up, a box fitting its flow
 * children with padding and gaps, and sizes come down, percent children taking their share of the parent's inner size,
 * then growing children sharing what is left by weight, or, when it is short, the largest children shrinking first down
 * to their minimums. Widths are solved first, so text wraps at its width before heights are. Positions follow, from the
 * distribution along the flow and the alignment across it, and last absolute nodes are placed against their parent or
 * their anchor.
 *
 * A text node holds its text as if it were its one flow child: a top-to-bottom node gives it the whole inner width, a
 * left-to-right one its unwrapped width at most. A node that clips an axis scrolls it, so its children keep their sizes
 * there and its content does not set its minimum.
 */
class LayoutSolver {
	final boxes:Array<LayoutBox> = [];
	final texts:Map<Int, TextSize> = new Map();
	final contents:Map<Int, ContentMeasures> = new Map();
	final indexOf:IntIndex = new IntIndex();
	final measure:TextMeasure = new TextMeasure();
	final spread:Spread = new Spread();
	var count:Int = 0;
	var session:Null<LayoutSession> = null;
	var fallbackMeasure:Null<LayoutMeasureCallback> = null;
	var viewportWidth:Float = 0.0;
	var viewportHeight:Float = 0.0;

	/** Seconds the last solve took, without the text it measured. */
	public var solveSeconds(default, null):Float = 0.0;

	/** Seconds the last solve spent measuring text. */
	public var textSeconds(default, null):Float = 0.0;

	/** Nodes the last solve laid out. */
	public var nodes(default, null):Int = 0;

	/** Content measurements asked for, answered from earlier ones, and made, since the solver was made. */
	public var measureRequests(default, null):Int = 0;
	public var measureHits(default, null):Int = 0;
	public var measureCalls(default, null):Int = 0;

	public function new() {}

	/** Text is measured with `session`'s fonts; Custom nodes without content of their own with `fallback`. */
	public function attach(session:LayoutSession, fallback:Null<LayoutMeasureCallback>):Void {
		this.session = session;
		this.fallbackMeasure = fallback;
	}

	/** Lays `root` out in a `width` by `height` viewport. */
	public function solve(root:LayoutNode, width:Float, height:Float):Void {
		textSeconds = 0.0;
		var started = Sys.time();
		viewportWidth = width;
		viewportHeight = height;
		count = 0;
		collect(root, -1);
		nodes = count;
		indexOf.clear();
		for (index in 0...count) {
			var box = boxes[index];
			indexOf.set(box.node.id, index);
			if (box.node.visualKind == LayoutVisualKind.Text) measureUnwrapped(box);
			else box.text = null;
			measureContent(box, -1.0);
		}
		var rootBox = boxes[0];
		var index = count - 1;
		while (index >= 0) fitAxis(index--, true);
		rootBox.width = rootSize(root.style.width, rootBox.fitWidth, rootBox.minWidth, width);
		for (index in 0...count) assignAxis(index, true);
		for (index in 0...count) {
			var box = boxes[index];
			if (box.text != null) layoutText(box);
			else if (box.measured && box.measuredWidth != box.width) measureContent(box, box.width);
		}
		index = count - 1;
		while (index >= 0) fitAxis(index--, false);
		rootBox.height = rootSize(root.style.height, rootBox.fitHeight, rootBox.minHeight, height);
		for (index in 0...count) assignAxis(index, false);
		index = count - 1;
		while (index >= 0) arrange(index--);
		rootBox.x = 0.0;
		rootBox.y = 0.0;
		for (index in 0...count) place(index);
		solveSeconds = Sys.time() - started - textSeconds;
	}

	/** Writes each node's geometry into `output` as `NKUI_LAYOUT_GEOMETRY_RECORD_BYTES` records, returning the length. */
	public function encode(output:Bytes):Int {
		var record = NativeKitUIConstants.NKUI_LAYOUT_GEOMETRY_RECORD_BYTES;
		var length = count * record;
		if (output.length < length) throw "Layout geometry exceeds its buffer";
		var offset = 0;
		for (index in 0...count) {
			var box = boxes[index];
			output.setInt32(offset, box.node.id);
			output.setFloat(offset + 4, box.x);
			output.setFloat(offset + 8, box.y);
			output.setFloat(offset + 12, box.width);
			output.setFloat(offset + 16, box.height);
			output.setFloat(offset + 20, box.textX);
			output.setFloat(offset + 24, box.textY);
			output.setFloat(offset + 28, box.textWidth);
			output.setFloat(offset + 32, box.ownBaseline ? box.y + box.baseline : Math.NaN);
			offset += record;
		}
		return length;
	}

	function collect(node:LayoutNode, parent:Int):Void {
		var index = count++;
		if (index == boxes.length) boxes.push(new LayoutBox());
		var box = boxes[index];
		box.node = node;
		box.parent = parent;
		box.flowChildren = 0;
		for (child in node.children) {
			if (child.style.positioning != LayoutPositioning.Absolute) box.flowChildren++;
			collect(child, index);
		}
		box.size = count - index;
	}

	function rootSize(axis:LayoutAxis, fit:Float, minimum:Float, available:Float):Float {
		return switch axis.sizing {
			case LayoutSizing.Fixed: axis.value;
			case LayoutSizing.Percent: available * axis.value;
			case LayoutSizing.Grow: clamp(available, axis.min, axis.max);
			default: Math.max(minimum, Math.min(fit, available));
		}
	}

	// Text

	function textSize(node:LayoutNode):TextSize {
		var size = texts.get(node.id);
		if (size == null) {
			size = new TextSize();
			texts.set(node.id, size);
		}
		var textStyle = node.peekTextStyle(), paragraph = node.peekParagraphStyle();
		if (size.text != node.text || size.fontSize != textStyle.fontSize || size.font != textStyle.font
			|| size.letterSpacing != textStyle.letterSpacing || size.lineHeight != paragraph.lineHeight
			|| size.wrap != paragraph.wrap || size.alignment != paragraph.alignment
			|| size.direction != paragraph.direction || size.tabWidth != paragraph.tabWidth) {
			size.text = node.text;
			size.fontSize = textStyle.fontSize;
			size.font = textStyle.font;
			size.letterSpacing = textStyle.letterSpacing;
			size.lineHeight = paragraph.lineHeight;
			size.wrap = paragraph.wrap;
			size.alignment = paragraph.alignment;
			size.direction = paragraph.direction;
			size.tabWidth = paragraph.tabWidth;
			size.measured = false;
			size.laidOutAt = -1.0;
		}
		return size;
	}

	function measureUnwrapped(box:LayoutBox):Void {
		var node = box.node;
		var size = textSize(node);
		box.text = size;
		if (size.measured) return;
		var started = Sys.time();
		var session = this.session;
		if (session == null) {
			size.unwrappedWidth = 0.0;
			size.unwrappedHeight = size.lineHeight == null ? 0.0 : size.lineHeight;
		} else {
			session.measureText(node.text, 0.0, node.peekTextStyle(), node.peekParagraphStyle(), measure);
			size.unwrappedWidth = measure.width;
			size.unwrappedHeight = measure.height;
		}
		size.measured = true;
		textSeconds += Sys.time() - started;
	}

	/** Lays the text out at the width its node gives it, for its height and baseline. */
	function layoutText(box:LayoutBox):Void {
		var node = box.node;
		var style = node.style;
		var inner = Math.max(0.0, box.width - style.padding.left - style.padding.right);
		var size = box.text;
		if (size == null) return;
		box.textWidth = style.direction == LayoutDirection.TopToBottom ? inner : Math.min(size.unwrappedWidth, inner);
		if (size.laidOutAt != box.textWidth) {
			var started = Sys.time();
			var session = this.session;
			if (session == null || box.textWidth <= 0.0) {
				size.height = size.lineHeight == null ? 0.0 : size.lineHeight;
				size.hasBaseline = false;
				size.baseline = 0.0;
			} else {
				session.measureText(node.text, box.textWidth, node.peekTextStyle(), node.peekParagraphStyle(), measure);
				size.height = measure.height;
				size.hasBaseline = measure.hasBaseline;
				size.baseline = measure.baseline;
			}
			size.laidOutAt = box.textWidth;
			textSeconds += Sys.time() - started;
		}
		box.textHeight = size.height;
	}

	// Custom content

	/** Measures a node's content, unconstrained by its parent, or at exactly `width` when it is positive. */
	function measureContent(box:LayoutBox, width:Float):Void {
		var node = box.node;
		box.measured = false;
		if (node.visualKind == LayoutVisualKind.Text) return;
		var content = node.intrinsicContent;
		var fallback = this.fallbackMeasure;
		if (content == null && (fallback == null || node.visualKind != LayoutVisualKind.Custom)) return;
		var style = node.style;
		var minWidth = width > 0.0 ? width : limit(style.width, true);
		var maxWidth = width > 0.0 ? width : limit(style.width, false);
		var constraints = new LayoutMeasureConstraints(minWidth, maxWidth, limit(style.height, true),
			limit(style.height, false));
		var version = content != null ? content.getVersion() : node.measureVersion;
		var cached = contents.get(node.id);
		if (cached == null) {
			cached = new ContentMeasures();
			contents.set(node.id, cached);
		}
		measureRequests++;
		var source:Dynamic = content != null ? content : fallback;
		var result = cached.find(source, version, constraints);
		if (result != null) measureHits++;
		else {
			measureCalls++;
			if (content != null) result = content.measure(constraints);
			else if (fallback != null) result = fallback(node.id, constraints);
			if (result != null) cached.keep(source, version, constraints, result);
		}
		if (result == null || !(result.width >= 0.0) || !(result.height >= 0.0)) return;
		box.measured = true;
		box.measuredWidth = clampRange(result.width, minWidth, maxWidth);
		box.measuredHeight = clampRange(result.height, constraints.minHeight, constraints.maxHeight);
		box.contentBaseline = result.baseline;
		box.contentHasBaseline = result.hasBaseline;
	}

	static function limit(axis:LayoutAxis, minimum:Bool):Float {
		return switch axis.sizing {
			case LayoutSizing.Fixed: axis.value;
			case LayoutSizing.Percent: minimum ? 0.0 : Math.POSITIVE_INFINITY;
			default: minimum ? Math.max(0.0, axis.min) : axis.max > 0.0 ? Math.max(axis.max,
				axis.min) : Math.POSITIVE_INFINITY;
		}
	}

	static inline function clampRange(value:Float, minimum:Float, maximum:Float):Float {
		return Math.min(Math.max(value, minimum), maximum);
	}

	// Sizes

	static inline function gapAlong(style:LayoutStyle, horizontal:Bool):Float {
		var gap = horizontal ? style.columnGap : style.rowGap;
		return gap != 0.0 ? gap : style.childGap;
	}

	function fitAxis(index:Int, horizontal:Bool):Void {
		var box = boxes[index];
		var node = box.node;
		var style = node.style;
		var axis = horizontal ? style.width : style.height;
		var main = horizontal == (style.direction == LayoutDirection.LeftToRight);
		var wraps = style.wrapMode == LayoutWrapMode.Wrap;
		var padding = horizontal ? style.padding.left + style.padding.right : style.padding.top + style.padding.bottom;
		var content = 0.0, minimum = 0.0;
		if (wraps && !main && !horizontal) {
			// Wrapped lines stack across the flow; their breaks are known once widths are.
			content = wrappedCross(index);
			minimum = content;
		} else {
			var child = index + 1;
			for (_ in 0...node.children.length) {
				var childBox = boxes[child];
				if (childBox.node.style.positioning != LayoutPositioning.Absolute) {
					var size = horizontal ? childBox.fitWidth : childBox.fitHeight;
					var least = horizontal ? childBox.minWidth : childBox.minHeight;
					if (main) {
						content += size;
						if (!wraps) minimum += least;
						else if (least > minimum) minimum = least;
					} else {
						if (size > content) content = size;
						if (least > minimum) minimum = least;
					}
				}
				child += childBox.size;
			}
			if (main && box.flowChildren > 1) {
				var gaps = gapAlong(style, horizontal) * (box.flowChildren - 1);
				content += gaps;
				if (!wraps) minimum += gaps;
			}
		}
		var text = box.text;
		if (text != null) {
			var size = horizontal ? text.unwrappedWidth : box.textHeight;
			if (size > content) content = size;
			// Text may wrap narrower, so it has no width minimum, but its lines need their height.
			if (!horizontal && size > minimum) minimum = size;
		}
		if (box.measured) {
			var size = horizontal ? box.measuredWidth : box.measuredHeight;
			if (size > content) content = size;
		}
		if (!horizontal && style.aspectRatio > 0.0 && box.width > 0.0) content = box.width / style.aspectRatio;
		// A node that clips an axis can be smaller than its content there, which it scrolls or hides.
		if (horizontal ? style.clipHorizontal : style.clipVertical) minimum = 0.0;
		content += padding;
		minimum += padding;
		var fit:Float, least:Float;
		switch axis.sizing {
			case LayoutSizing.Fixed:
				fit = least = axis.value;
			case LayoutSizing.Percent:
				fit = least = 0.0;
			default:
				fit = clamp(content, axis.min, axis.max);
				least = clamp(minimum, axis.min, axis.max);
		}
		if (horizontal) {
			box.fitWidth = fit;
			box.minWidth = least;
		} else {
			box.fitHeight = fit;
			box.minHeight = least;
		}
	}

	function assignAxis(index:Int, horizontal:Bool):Void {
		var box = boxes[index];
		var node = box.node;
		if (node.children.length == 0) return;
		var style = node.style;
		var main = horizontal == (style.direction == LayoutDirection.LeftToRight);
		var outer = horizontal ? box.width : box.height;
		var inner = Math.max(0.0, horizontal ? box.width - style.padding.left - style.padding.right : box.height
			- style.padding.top - style.padding.bottom);
		var clips = horizontal ? style.clipHorizontal : style.clipVertical;
		var child = index + 1;
		var used = 0.0, weights = 0.0;
		for (_ in 0...node.children.length) {
			var childBox = boxes[child];
			var childStyle = childBox.node.style;
			var axis = horizontal ? childStyle.width : childStyle.height;
			var fit = horizontal ? childBox.fitWidth : childBox.fitHeight;
			var least = horizontal ? childBox.minWidth : childBox.minHeight;
			var size:Float;
			if (childStyle.positioning == LayoutPositioning.Absolute) {
				// An absolute node is sized against its parent's whole box, as it is placed against it.
				size = switch axis.sizing {
					case LayoutSizing.Fixed: axis.value;
					case LayoutSizing.Percent: outer * axis.value;
					case LayoutSizing.Grow: clamp(outer, axis.min, axis.max);
					default: fit;
				}
			} else if (!main) {
				// Across the flow a child is kept inside, down to its minimum, unless the parent scrolls there.
				var room = clips ? Math.max(inner, fit) : inner;
				size = switch axis.sizing {
					case LayoutSizing.Fixed: axis.value;
					case LayoutSizing.Percent: inner * axis.value;
					case LayoutSizing.Grow: Math.max(least, axis.max > 0.0 ? Math.min(room, axis.max) : room);
					default: Math.max(least, Math.min(fit, room));
				}
			} else {
				size = axis.sizing == LayoutSizing.Percent ? inner * axis.value : fit;
				used += size;
				if (axis.sizing == LayoutSizing.Grow) weights += axis.growWeight;
			}
			if (horizontal) childBox.width = size;
			else childBox.height = size;
			child += childBox.size;
		}
		if (!main || box.flowChildren == 0) return;
		if (style.wrapMode == LayoutWrapMode.Wrap) {
			breakLines(index, horizontal, inner);
			return;
		}
		var remaining = inner - used - gapAlong(style, horizontal) * (box.flowChildren - 1);
		if (remaining > 0.01 && weights > 0.0) grow(index, horizontal, remaining, weights, -1);
		else if (remaining < -0.01 && !clips) shrink(index, horizontal, -remaining);
	}

	/** Shares `remaining` among the growing flow children (of line `line`, or all) by weight, up to their maximums. */
	function grow(index:Int, horizontal:Bool, remaining:Float, weights:Float, line:Int):Void {
		var node = boxes[index].node;
		while (remaining > 0.01 && weights > 0.0) {
			var share = remaining / weights, given = 0.0, capped = 0.0;
			var child = index + 1;
			for (_ in 0...node.children.length) {
				var childBox = boxes[child];
				var childStyle = childBox.node.style;
				var axis = horizontal ? childStyle.width : childStyle.height;
				if (childStyle.positioning != LayoutPositioning.Absolute && axis.sizing == LayoutSizing.Grow
					&& (line < 0 || childBox.line == line)) {
					var size = horizontal ? childBox.width : childBox.height;
					if (axis.max <= 0.0 || size < axis.max) {
						var next = size + share * axis.growWeight;
						if (axis.max > 0.0 && next >= axis.max) {
							next = axis.max;
							capped += axis.growWeight;
						}
						given += next - size;
						if (horizontal) childBox.width = next;
						else childBox.height = next;
					}
				}
				child += childBox.size;
			}
			remaining -= given;
			if (capped == 0.0) break;
			weights -= capped;
		}
	}

	/** Takes `excess` from the largest shrinkable flow children first, each down to its minimum. */
	function shrink(index:Int, horizontal:Bool, excess:Float):Void {
		var node = boxes[index].node;
		var rounds = 0;
		while (excess > 0.01 && rounds++ < 64) {
			var largest = 0.0, second = 0.0, sharing = 0;
			var child = index + 1;
			for (_ in 0...node.children.length) {
				var childBox = boxes[child];
				if (shrinkable(childBox, horizontal)) {
					var size = horizontal ? childBox.width : childBox.height;
					if (size > largest + 0.01) {
						second = largest;
						largest = size;
						sharing = 1;
					} else if (Math.abs(size - largest) <= 0.01) sharing++;
					else if (size > second) second = size;
				}
				child += childBox.size;
			}
			if (sharing == 0) return;
			var cut = Math.min(excess / sharing, largest - second);
			if (cut <= 0.0) cut = excess / sharing;
			var taken = 0.0;
			child = index + 1;
			for (_ in 0...node.children.length) {
				var childBox = boxes[child];
				if (shrinkable(childBox, horizontal)) {
					var size = horizontal ? childBox.width : childBox.height;
					if (Math.abs(size - largest) <= 0.01) {
						var least = horizontal ? childBox.minWidth : childBox.minHeight;
						var next = Math.max(least, size - cut);
						taken += size - next;
						if (horizontal) childBox.width = next;
						else childBox.height = next;
					}
				}
				child += childBox.size;
			}
			if (taken <= 0.0) return;
			excess -= taken;
		}
	}

	static function shrinkable(box:LayoutBox, horizontal:Bool):Bool {
		var style = box.node.style;
		if (style.positioning == LayoutPositioning.Absolute) return false;
		var axis = horizontal ? style.width : style.height;
		var size = horizontal ? box.width : box.height;
		var least = horizontal ? box.minWidth : box.minHeight;
		return (axis.sizing == LayoutSizing.Fit || axis.sizing == LayoutSizing.Grow) && size > least + 0.01;
	}

	/** Breaks a wrapping node's flow children into lines that fit `available`, then grows each line's children. */
	function breakLines(index:Int, horizontal:Bool, available:Float):Void {
		var box = boxes[index];
		var node = box.node;
		var gap = gapAlong(node.style, horizontal);
		var line = -1, lineSize = 0.0, lineCount = 0;
		var child = index + 1;
		for (_ in 0...node.children.length) {
			var childBox = boxes[child];
			if (childBox.node.style.positioning != LayoutPositioning.Absolute) {
				var size = horizontal ? childBox.width : childBox.height;
				if (line < 0 || (lineCount > 0 && lineSize + gap + size > available)) {
					line++;
					lineSize = 0.0;
					lineCount = 0;
				}
				lineSize += (lineCount > 0 ? gap : 0.0) + size;
				lineCount++;
				childBox.line = line;
			}
			child += childBox.size;
		}
		box.lines = line + 1;
		for (each in 0...box.lines) {
			var used = 0.0, weights = 0.0, members = 0;
			child = index + 1;
			for (_ in 0...node.children.length) {
				var childBox = boxes[child];
				var childStyle = childBox.node.style;
				if (childStyle.positioning != LayoutPositioning.Absolute && childBox.line == each) {
					used += horizontal ? childBox.width : childBox.height;
					var axis = horizontal ? childStyle.width : childStyle.height;
					if (axis.sizing == LayoutSizing.Grow) weights += axis.growWeight;
					members++;
				}
				child += childBox.size;
			}
			var remaining = available - used - gap * (members - 1);
			if (remaining > 0.01 && weights > 0.0) grow(index, horizontal, remaining, weights, each);
		}
	}

	/** The extent across the flow of a wrapping node's lines, stacked with their gaps. */
	function wrappedCross(index:Int):Float {
		var box = boxes[index];
		var style = box.node.style;
		var horizontal = style.direction == LayoutDirection.LeftToRight;
		var total = 0.0;
		for (each in 0...box.lines) {
			total += lineCross(index, each, horizontal, true);
			if (each > 0) total += gapAlong(style, !horizontal);
		}
		return total;
	}

	/** The largest extent across the flow of line `line`'s children: their fit sizes while fitting, else their sizes. */
	function lineCross(index:Int, line:Int, horizontal:Bool, fitting:Bool):Float {
		var node = boxes[index].node;
		var cross = 0.0;
		var child = index + 1;
		for (_ in 0...node.children.length) {
			var childBox = boxes[child];
			if (childBox.node.style.positioning != LayoutPositioning.Absolute && childBox.line == line) {
				var size = horizontal
					? (fitting ? childBox.fitHeight : childBox.height) : (fitting ? childBox.fitWidth : childBox.width);
				if (size > cross) cross = size;
			}
			child += childBox.size;
		}
		return cross;
	}

	// Positions

	/**
	 * Places a node's flow children relative to its own origin, and its text, and finds its baseline. Children are
	 * arranged before their parent, so a parent aligns its children by baselines that are already known.
	 */
	function arrange(index:Int):Void {
		var box = boxes[index];
		var node = box.node;
		var style = node.style;
		var horizontal = style.direction == LayoutDirection.LeftToRight;
		var innerWidth = Math.max(0.0, box.width - style.padding.left - style.padding.right);
		var innerHeight = Math.max(0.0, box.height - style.padding.top - style.padding.bottom);
		box.hasBaseline = false;
		box.baseline = 0.0;
		var text = box.text;
		if (text != null) {
			var freeWidth = Math.max(0.0, innerWidth - box.textWidth);
			var freeHeight = Math.max(0.0, innerHeight - box.textHeight);
			box.textX = style.padding.left
				+ (horizontal ? distribute(style.childDistribution, 1, freeWidth).leading : 0.0);
			box.textY = style.padding.top
				+ (horizontal ? alignY(style.childAlignY, freeHeight) : distribute(style.childDistribution, 1,
				freeHeight).leading);
			if (text.hasBaseline) {
				box.hasBaseline = true;
				box.baseline = box.textY + text.baseline;
			}
		} else {
			box.textX = box.textY = box.textWidth = box.textHeight = 0.0;
			if (box.measured && box.contentHasBaseline && box.contentBaseline >= 0.0
				&& box.contentBaseline <= box.height) {
				box.hasBaseline = true;
				box.baseline = box.contentBaseline;
			}
		}
		box.ownBaseline = box.hasBaseline;
		if (node.children.length == 0) return;
		if (style.wrapMode == LayoutWrapMode.Wrap) arrangeLines(index, innerWidth, innerHeight);
		else arrangeFlow(index, horizontal, innerWidth, innerHeight);
		// A node with one child and no baseline of its own takes the child's, so rows align through wrappers.
		if (!box.hasBaseline && node.children.length == 1 && box.flowChildren == 1) {
			var childBox = boxes[index + 1];
			if (childBox.hasBaseline) {
				box.hasBaseline = true;
				box.baseline = childBox.y + childBox.baseline;
			}
		}
	}

	function arrangeFlow(index:Int, horizontal:Bool, innerWidth:Float, innerHeight:Float):Void {
		var box = boxes[index];
		var node = box.node;
		var style = node.style;
		var used = 0.0, baseline = 0.0;
		var child = index + 1;
		for (_ in 0...node.children.length) {
			var childBox = boxes[child];
			if (childBox.node.style.positioning != LayoutPositioning.Absolute) {
				used += horizontal ? childBox.width : childBox.height;
				if (horizontal
					&& alignmentY(childBox.node.style.alignSelf, style.childAlignY) == LayoutAlignmentY.Baseline)
					baseline = Math.max(baseline, childBox.hasBaseline ? childBox.baseline : childBox.height);
			}
			child += childBox.size;
		}
		var flow = box.flowChildren;
		var gap = gapAlong(style, horizontal);
		if (flow > 1) used += gap * (flow - 1);
		var spread = distribute(style.childDistribution, flow,
			Math.max(0.0, (horizontal ? innerWidth : innerHeight) - used));
		var cursor = spread.leading;
		gap += spread.gap;
		child = index + 1;
		for (_ in 0...node.children.length) {
			var childBox = boxes[child];
			var childStyle = childBox.node.style;
			if (childStyle.positioning == LayoutPositioning.Absolute) {
				childBox.x = childStyle.positionX;
				childBox.y = childStyle.positionY;
			} else if (horizontal) {
				childBox.x = style.padding.left + cursor;
				var align = alignmentY(childStyle.alignSelf, style.childAlignY);
				childBox.y = style.padding.top
					+ (align == LayoutAlignmentY.Baseline
					? baseline - (childBox.hasBaseline ? childBox.baseline : childBox.height) : alignY(align,
					innerHeight - childBox.height));
				cursor += childBox.width + gap;
			} else {
				childBox.y = style.padding.top + cursor;
				childBox.x = style.padding.left
					+ alignX(alignmentX(childStyle.alignSelf, style.childAlignX), innerWidth - childBox.width);
				cursor += childBox.height + gap;
			}
			child += childBox.size;
		}
	}

	function arrangeLines(index:Int, innerWidth:Float, innerHeight:Float):Void {
		var box = boxes[index];
		var node = box.node;
		var style = node.style;
		var horizontal = style.direction == LayoutDirection.LeftToRight;
		var mainGap = gapAlong(style, horizontal), crossGap = gapAlong(style, !horizontal);
		var total = 0.0;
		for (each in 0...box.lines) {
			total += lineCross(index, each, horizontal, false);
			if (each > 0) total += crossGap;
		}
		var crossFree = Math.max(0.0, (horizontal ? innerHeight : innerWidth) - total);
		var crossOffset = horizontal ? alignY(style.childAlignY, crossFree) : alignX(style.childAlignX, crossFree);
		var child = index + 1;
		for (_ in 0...node.children.length) {
			var childBox = boxes[child];
			var childStyle = childBox.node.style;
			if (childStyle.positioning == LayoutPositioning.Absolute) {
				childBox.x = childStyle.positionX;
				childBox.y = childStyle.positionY;
			}
			child += childBox.size;
		}
		for (each in 0...box.lines) {
			var cross = lineCross(index, each, horizontal, false);
			var used = 0.0, members = 0, baseline = 0.0;
			child = index + 1;
			for (_ in 0...node.children.length) {
				var childBox = boxes[child];
				if (childBox.node.style.positioning != LayoutPositioning.Absolute && childBox.line == each) {
					used += (members > 0 ? mainGap : 0.0) + (horizontal ? childBox.width : childBox.height);
					if (horizontal) baseline = Math.max(baseline,
						childBox.hasBaseline ? childBox.baseline : childBox.height);
					members++;
				}
				child += childBox.size;
			}
			var spread = distribute(style.childDistribution, members,
				Math.max(0.0, (horizontal ? innerWidth : innerHeight) - used));
			var cursor = spread.leading, gap = mainGap + spread.gap;
			child = index + 1;
			for (_ in 0...node.children.length) {
				var childBox = boxes[child];
				var childStyle = childBox.node.style;
				if (childStyle.positioning != LayoutPositioning.Absolute && childBox.line == each) {
					if (horizontal) {
						childBox.x = style.padding.left + cursor;
						var align = alignmentY(childStyle.alignSelf, style.childAlignY);
						childBox.y = style.padding.top + crossOffset
							+ (align == LayoutAlignmentY.Baseline
							? baseline - (childBox.hasBaseline ? childBox.baseline : childBox.height) : alignY(align,
							cross - childBox.height));
						cursor += childBox.width + gap;
					} else {
						childBox.y = style.padding.top + cursor;
						childBox.x = style.padding.left + crossOffset
							+ alignX(alignmentX(childStyle.alignSelf, style.childAlignX), cross - childBox.width);
						cursor += childBox.height + gap;
					}
				}
				child += childBox.size;
			}
			crossOffset += cross + crossGap;
		}
	}

	/**
	 * Turns positions relative to the parent into layout coordinates, and places anchored nodes. Parents are placed
	 * before their children, and a referenced node before the node anchored to it, so each placement reads final bounds.
	 */
	function place(index:Int):Void {
		var box = boxes[index];
		if (box.parent >= 0) {
			var parent = boxes[box.parent];
			box.x += parent.x;
			box.y += parent.y;
		}
		box.composeWorld(box.parent < 0 ? null : boxes[box.parent]);
		var anchor = box.node.anchor;
		if (anchor != null) placeAnchored(index, anchor);
	}

	final target:AnchorRect = new AnchorRect();
	final region:AnchorRect = new AnchorRect();
	final current:AnchorRect = new AnchorRect();

	function placeAnchored(index:Int, anchor:LayoutAnchor):Void {
		var box = boxes[index];
		switch anchor.target {
			case Node(id):
				worldBounds(earlier(id, index), target);
			case Area(rect):
				target.set(rect.x, rect.y, rect.width, rect.height);
		}
		region.set(0.0, 0.0, viewportWidth, viewportHeight);
		switch anchor.within {
			case Viewport:
			case Node(id):
				worldBounds(earlier(id, index), region);
			case Area(rect):
				region.set(rect.x, rect.y, rect.width, rect.height);
		}
		worldBounds(index, current);
		var w = current.width, h = current.height, margin = anchor.margin;
		var left = region.x + margin, top = region.y + margin;
		var right = region.x + region.width - margin, bottom = region.y + region.height - margin;
		var vertical = anchor.side == AnchorSide.Below || anchor.side == AnchorSide.Above;
		var x = target.x, y = target.y;
		if (anchor.side != AnchorSide.Overlap) {
			var side = anchor.side;
			// The opposite side when the node overflows on its own and the opposite has more room.
			var here = room(side, anchor.gap, left, top, right, bottom);
			if (anchor.flip && here < (vertical ? h : w)
				&& room(opposite(side), anchor.gap, left, top, right, bottom) > here)
				side = opposite(side);
			var along = switch side {
				case AnchorSide.Below: target.y + target.height + anchor.gap;
				case AnchorSide.Above: target.y - anchor.gap - h;
				case AnchorSide.After: target.x + target.width + anchor.gap;
				case AnchorSide.Before: target.x - anchor.gap - w;
				default: 0.0;
			}
			var across = vertical ? crossStart(target.x, target.width, w, anchor.align,
				anchor.boxAlign) : crossStart(target.y, target.height, h, anchor.align, anchor.boxAlign);
			var size = vertical ? w : h, limit = vertical ? right : bottom, floor = vertical ? left : top;
			if (anchor.flipCross && across + size > limit) {
				var swapped = vertical ? crossStart(target.x, target.width, w, 1.0 - anchor.align,
					1.0 - anchor.boxAlign) : crossStart(target.y, target.height, h, 1.0 - anchor.align,
					1.0 - anchor.boxAlign);
				if (swapped >= floor) across = swapped;
			}
			x = vertical ? across : along;
			y = vertical ? along : across;
		}
		x += box.node.style.positionX;
		y += box.node.style.positionY;
		// Kept inside the region; one larger than it keeps its start edge inside. A node that does not flip stays on its
		// side, so the region holds it on the cross axis only.
		if (anchor.side == AnchorSide.Overlap || vertical || anchor.flip) x = Math.max(left, Math.min(x, right - w));
		if (anchor.side == AnchorSide.Overlap || !vertical || anchor.flip) y = Math.max(top, Math.min(y, bottom - h));
		var dx = x - current.x, dy = y - current.y;
		if (box.parent >= 0) {
			// The shift is in viewport space; the node moves in its parent's layout space.
			var parent = boxes[box.parent];
			var determinant = parent.wa * parent.wd - parent.wb * parent.wc;
			if (Math.abs(determinant) < 0.000001) throw "An anchored node's parent transform is not invertible";
			var layoutX = (parent.wd * dx - parent.wc * dy) / determinant;
			var layoutY = (parent.wa * dy - parent.wb * dx) / determinant;
			dx = layoutX;
			dy = layoutY;
		}
		if (dx == 0.0 && dy == 0.0) return;
		// Its descendants are placed after it, from its new position.
		box.x += dx;
		box.y += dy;
		box.composeWorld(box.parent < 0 ? null : boxes[box.parent]);
	}

	function earlier(id:Int, anchored:Int):Int {
		var index = indexOf.get(id);
		if (index < 0 || index >= anchored) throw "A layout anchor must name a node before the anchored node";
		return index;
	}

	function room(side:AnchorSide, gap:Float, left:Float, top:Float, right:Float, bottom:Float):Float {
		return switch side {
			case AnchorSide.Below: bottom - (target.y + target.height + gap);
			case AnchorSide.Above: (target.y - gap) - top;
			case AnchorSide.After: right - (target.x + target.width + gap);
			case AnchorSide.Before: (target.x - gap) - left;
			default: 0.0;
		}
	}

	static function opposite(side:AnchorSide):AnchorSide {
		return switch side {
			case AnchorSide.Below: AnchorSide.Above;
			case AnchorSide.Above: AnchorSide.Below;
			case AnchorSide.After: AnchorSide.Before;
			case AnchorSide.Before: AnchorSide.After;
			default: side;
		}
	}

	static inline function crossStart(start:Float, extent:Float, size:Float, align:Float, boxAlign:Float):Float {
		return start + extent * align - size * boxAlign;
	}

	/** The axis-aligned bounds, in viewport coordinates, of box `index` under its world transform. */
	function worldBounds(index:Int, out:AnchorRect):Void {
		var box = boxes[index];
		var x0 = box.x, y0 = box.y, x1 = box.x + box.width, y1 = box.y + box.height;
		var ax = box.wa * x0 + box.wc * y0 + box.wtx, ay = box.wb * x0 + box.wd * y0 + box.wty;
		var bx = box.wa * x1 + box.wc * y0 + box.wtx, by = box.wb * x1 + box.wd * y0 + box.wty;
		var cx = box.wa * x0 + box.wc * y1 + box.wtx, cy = box.wb * x0 + box.wd * y1 + box.wty;
		var ex = box.wa * x1 + box.wc * y1 + box.wtx, ey = box.wb * x1 + box.wd * y1 + box.wty;
		var minX = Math.min(Math.min(ax, bx), Math.min(cx, ex)), maxX = Math.max(Math.max(ax, bx), Math.max(cx, ex));
		var minY = Math.min(Math.min(ay, by), Math.min(cy, ey)), maxY = Math.max(Math.max(ay, by), Math.max(cy, ey));
		out.set(minX, minY, maxX - minX, maxY - minY);
	}

	static function alignmentX(self:LayoutSelfAlignment, inherited:LayoutAlignmentX):LayoutAlignmentX {
		return switch self {
			case LayoutSelfAlignment.Start: LayoutAlignmentX.Start;
			case LayoutSelfAlignment.End: LayoutAlignmentX.End;
			case LayoutSelfAlignment.Center: LayoutAlignmentX.Center;
			default: inherited;
		}
	}

	static function alignmentY(self:LayoutSelfAlignment, inherited:LayoutAlignmentY):LayoutAlignmentY {
		return switch self {
			case LayoutSelfAlignment.Start: LayoutAlignmentY.Start;
			case LayoutSelfAlignment.End: LayoutAlignmentY.End;
			case LayoutSelfAlignment.Center: LayoutAlignmentY.Center;
			case LayoutSelfAlignment.Baseline: LayoutAlignmentY.Baseline;
			default: inherited;
		}
	}

	static inline function alignX(align:LayoutAlignmentX, free:Float):Float {
		return align == LayoutAlignmentX.Center ? free * 0.5 : align == LayoutAlignmentX.End ? free : 0.0;
	}

	static inline function alignY(align:LayoutAlignmentY, free:Float):Float {
		return align == LayoutAlignmentY.Center ? free * 0.5 : align == LayoutAlignmentY.End ? free : 0.0;
	}

	/** Where `count` children start and the extra gap between them, sharing `free` space by `distribution`. */
	function distribute(distribution:LayoutDistribution, count:Int, free:Float):Spread {
		spread.leading = 0.0;
		spread.gap = 0.0;
		if (count <= 0 || free <= 0.0) return spread;
		switch distribution {
			case LayoutDistribution.Center:
				spread.leading = free * 0.5;
			case LayoutDistribution.End:
				spread.leading = free;
			case LayoutDistribution.SpaceBetween:
				if (count > 1) spread.gap = free / (count - 1);
			case LayoutDistribution.SpaceAround:
				spread.leading = free / (count * 2.0);
				spread.gap = free / count;
			case LayoutDistribution.SpaceEvenly:
				spread.leading = spread.gap = free / (count + 1.0);
			default:
		}
		return spread;
	}

	static inline function clamp(value:Float, minimum:Float, maximum:Float):Float {
		var result = value < minimum ? minimum : value;
		return maximum > 0.0 && result > maximum ? maximum : result;
	}
}

/** One node's layout state for a solve. */
private class LayoutBox {
	public var node:LayoutNode = null;
	public var parent:Int = -1;
	/** Boxes in this subtree, itself included: the next sibling's box is this many after this one. */
	public var size:Int = 1;
	public var flowChildren:Int = 0;
	public var fitWidth:Float = 0.0;
	public var minWidth:Float = 0.0;
	public var fitHeight:Float = 0.0;
	public var minHeight:Float = 0.0;
	public var width:Float = 0.0;
	public var height:Float = 0.0;
	/** Relative to the parent while arranging, then in layout coordinates. */
	public var x:Float = 0.0;
	public var y:Float = 0.0;
	public var baseline:Float = 0.0;
	public var hasBaseline:Bool = false;
	/** Whether the baseline is its text's or its content's own, not taken from a child. */
	public var ownBaseline:Bool = false;
	/** For a wrapping parent's child, the line it is on; for a wrapping box, its number of lines. */
	public var line:Int = 0;
	public var lines:Int = 0;
	public var text:Null<TextSize> = null;
	/** Where the text goes, relative to the box, and its width and height there. */
	public var textX:Float = 0.0;
	public var textY:Float = 0.0;
	public var textWidth:Float = 0.0;
	public var textHeight:Float = 0.0;
	public var measured:Bool = false;
	public var measuredWidth:Float = 0.0;
	public var measuredHeight:Float = 0.0;
	public var contentBaseline:Float = 0.0;
	public var contentHasBaseline:Bool = false;
	/** The world transform: x' = wa x + wc y + wtx, y' = wb x + wd y + wty. */
	public var wa:Float = 1.0;
	public var wb:Float = 0.0;
	public var wc:Float = 0.0;
	public var wd:Float = 1.0;
	public var wtx:Float = 0.0;
	public var wty:Float = 0.0;

	public function new() {}

	/** The parent's world transform, then this node's own transform about its origin in its bounds. */
	public function composeWorld(parent:Null<LayoutBox>):Void {
		var style = node.style;
		var transform = style.transform;
		var originX = x + width * style.transformOriginX, originY = y + height * style.transformOriginY;
		var la = transform.a, lb = transform.b, lc = transform.c, ld = transform.d;
		var ltx = originX + transform.tx - (la * originX + lc * originY);
		var lty = originY + transform.ty - (lb * originX + ld * originY);
		if (parent == null) {
			wa = la;
			wb = lb;
			wc = lc;
			wd = ld;
			wtx = ltx;
			wty = lty;
		} else {
			wa = parent.wa * la + parent.wc * lb;
			wb = parent.wb * la + parent.wd * lb;
			wc = parent.wa * lc + parent.wc * ld;
			wd = parent.wb * lc + parent.wd * ld;
			wtx = parent.wa * ltx + parent.wc * lty + parent.wtx;
			wty = parent.wb * ltx + parent.wd * lty + parent.wty;
		}
	}
}

/**
 * A node's last content measurements: one unconstrained by its parent and one at the width it was given, kept while the
 * same content, or measure callback, at the same version measures it.
 */
private class ContentMeasures {
	var source:Dynamic = null;
	var version:Int = -1;
	final constraints:Array<LayoutMeasureConstraints> = [];
	final results:Array<LayoutMeasureResult> = [];

	public function new() {}

	public function find(source:Dynamic, version:Int, constraints:LayoutMeasureConstraints):Null<LayoutMeasureResult> {
		if (source != this.source || version != this.version) return null;
		for (index in 0...this.constraints.length) {
			var kept = this.constraints[index];
			if (kept.minWidth == constraints.minWidth && kept.maxWidth == constraints.maxWidth
				&& kept.minHeight == constraints.minHeight && kept.maxHeight == constraints.maxHeight)
				return results[index];
		}
		return null;
	}

	public function keep(source:Dynamic, version:Int, constraints:LayoutMeasureConstraints,
			result:LayoutMeasureResult):Void {
		if (source != this.source || version != this.version || this.constraints.length >= 2) {
			this.source = source;
			this.version = version;
			this.constraints.resize(0);
			results.resize(0);
		}
		this.constraints.push(constraints);
		results.push(result);
	}
}

/** A node's text measurements, kept while its text and styles stay the same. */
private class TextSize {
	public var text:Null<String> = null;
	public var fontSize:Float = -1.0;
	public var font:Null<FontFamily> = null;
	public var letterSpacing:Float = 0.0;
	public var lineHeight:Null<Float> = null;
	public var wrap:Null<TextWrap> = null;
	public var alignment:Null<TextAlignment> = null;
	public var direction:Null<TextDirection> = null;
	public var tabWidth:Int = 0;
	public var measured:Bool = false;
	public var unwrappedWidth:Float = 0.0;
	public var unwrappedHeight:Float = 0.0;
	/** The width it was last laid out at, and its height and baseline there. */
	public var laidOutAt:Float = -1.0;
	public var height:Float = 0.0;
	public var baseline:Float = 0.0;
	public var hasBaseline:Bool = false;

	public function new() {}
}

private class AnchorRect {
	public var x:Float = 0.0;
	public var y:Float = 0.0;
	public var width:Float = 0.0;
	public var height:Float = 0.0;

	public function new() {}

	public inline function set(x:Float, y:Float, width:Float, height:Float):Void {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
	}
}

private class Spread {
	public var leading:Float = 0.0;
	public var gap:Float = 0.0;

	public function new() {}
}
