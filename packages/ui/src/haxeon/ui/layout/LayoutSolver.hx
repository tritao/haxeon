package haxeon.ui.layout;

import haxe.io.Bytes;
import haxeon.ui.IntIndex;
import haxeon.ui.LayoutAnchor;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutContent;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutPlacer;
import haxeon.ui.LayoutScroll;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.TextStyle;
import haxeon.ui.Transform2D;

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
	/** Each node's item from the last resolution, and from this one; swapped after each, so removed nodes drop out. */
	var previousItems:Map<Int, ResolvedLayoutItem> = new Map();
	var nextItems:Map<Int, ResolvedLayoutItem> = new Map();
	/** Each node's geometry as last encoded, and as this resolution has it; swapped like the items. */
	var previousPlaced:Map<Int, PlacedGeometry> = new Map();
	var nextPlaced:Map<Int, PlacedGeometry> = new Map();
	final resolvedItems:Array<ResolvedLayoutItem> = [];
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

	public function new() {
		locator = new LayoutLocator(function(id:Int, out:LayoutLocator):Bool {
			var index = indexOf.get(id);
			var content = locatingIn;
			if (content < 0 || index <= content || index >= content + boxes[content].size) return false;
			var box = boxes[index];
			var x = 0.0, y = 0.0, at = index;
			while (at != content) {
				x += boxes[at].x;
				y += boxes[at].y;
				at = boxes[at].parent;
			}
			out.set(x, y, box.width, box.height);
			return true;
		});
	}

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
		layOut(0, -1.0, -1.0);
		rootBox.x = 0.0;
		rootBox.y = 0.0;
		// Placed subtrees go after everything else, so their placers read scroll offsets settled anywhere in the tree.
		placedLater.resize(0);
		var index = 0;
		while (index < count) {
			var box = boxes[index];
			if (index > 0 && box.node.placer != null && box.node.style.positioning == LayoutPositioning.Absolute) {
				placedLater.push(index);
				index += box.size;
			} else place(index++);
		}
		for (first in placedLater) for (each in first...first + boxes[first].size) place(each);
		solveSeconds = Sys.time() - started - textSeconds;
	}

	/**
	 * The resolved geometry of the last solve, in tree order: each node's layout bounds, world transform, the clip it
	 * inherits in viewport coordinates, the bounds of its children relative to its padded origin, whether it is drawn,
	 * and its baseline. An item equal to the node's previous one is that same item.
	 */
	public function resolve():Array<ResolvedLayoutItem> {
		resolvedItems.resize(count);
		for (index in 0...count) {
			var box = boxes[index];
			var style = box.node.style;
			var parent = box.parent < 0 ? null : boxes[box.parent];
			box.visible = (parent == null || parent.visible) && style.visible && !box.hidden;
			// The inherited clip: the viewport at the root, the parent's clip for its children, and for a floating node
			// the parent's own clip and bounds when it is clipped to its parent, else nothing but the viewport.
			if (parent == null) box.setClip(0.0, 0.0, viewportWidth, viewportHeight);
			else if (style.positioning == LayoutPositioning.Absolute) {
				if (style.clipToParent) {
					worldBounds(box.parent, current);
					box.setClip(parent.clipX, parent.clipY, parent.clipWidth, parent.clipHeight);
					box.intersectClip(current, true, true);
				} else box.setClip(0.0, 0.0, viewportWidth, viewportHeight);
			} else box.setClip(parent.childClipX, parent.childClipY, parent.childClipWidth, parent.childClipHeight);
			box.childClipX = box.clipX;
			box.childClipY = box.clipY;
			box.childClipWidth = box.clipWidth;
			box.childClipHeight = box.clipHeight;
			if (style.clipHorizontal || style.clipVertical) {
				worldBounds(index, current);
				box.intersectChildClip(current, style.clipHorizontal, style.clipVertical);
			}
			var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0, any = false;
			var originX = box.x + style.padding.left, originY = box.y + style.padding.top;
			var child = index + 1;
			for (_ in 0...box.node.children.length) {
				var childBox = boxes[child];
				var childLeft = childBox.x - originX, childTop = childBox.y - originY;
				if (!any) {
					left = childLeft;
					top = childTop;
					right = childLeft + childBox.width;
					bottom = childTop + childBox.height;
					any = true;
				} else {
					left = Math.min(left, childLeft);
					top = Math.min(top, childTop);
					right = Math.max(right, childLeft + childBox.width);
					bottom = Math.max(bottom, childTop + childBox.height);
				}
				child += childBox.size;
			}
			var flags = (box.visible ? 1 : 0) | (box.ownBaseline ? 2 : 0);
			var baseline = box.ownBaseline ? box.y + box.baseline : 0.0;
			var text = box.text;
			var shown = text == null ? null : text.shown;
			var previous = previousItems.get(box.node.id);
			var item = previous != null && previous.shownText == shown && previous.flags == flags && previous.x == box.x
				&& previous.y == box.y
				&& previous.width == box.width && previous.height == box.height && previous.baseline == baseline
				&& previous.clipBounds.x == box.clipX && previous.clipBounds.y == box.clipY
				&& previous.clipBounds.width == box.clipWidth && previous.clipBounds.height == box.clipHeight
				&& previous.contentBounds.x == left && previous.contentBounds.y == top
				&& previous.contentBounds.width == right - left && previous.contentBounds.height == bottom - top
				&& previous.transform.a == box.wa && previous.transform.b == box.wb && previous.transform.c == box.wc
				&& previous.transform.d == box.wd && previous.transform.tx == box.wtx
				&& previous.transform.ty == box.wty ? previous : new ResolvedLayoutItem(box.node.id, flags, box.x,
				box.y,
				box.width, box.height, new Rect(box.clipX, box.clipY, box.clipWidth, box.clipHeight),
				new Rect(left, top, right - left, bottom - top),
				new Transform2D(box.wa, box.wb, box.wc, box.wd, box.wtx,
				box.wty), baseline, shown);
			nextItems.set(box.node.id, item);
			var placed = previousPlaced.get(box.node.id);
			if (placed == null || !placed.matches(box)) {
				if (placed == null) placed = new PlacedGeometry();
				placed.take(box);
				changedNodes.push(box.node.id);
			}
			nextPlaced.set(box.node.id, placed);
			resolvedItems[index] = item;
		}
		var last = previousItems;
		last.clear();
		previousItems = nextItems;
		nextItems = last;
		resolveHitTesting();
		var lastPlaced = previousPlaced;
		lastPlaced.clear();
		previousPlaced = nextPlaced;
		nextPlaced = lastPlaced;
		return resolvedItems;
	}

	/**
	 * The IDs of the nodes from the root down to the topmost one under (`x`, `y`) in viewport coordinates that takes the
	 * pointer, into `path`; empty when none does. Topmost is last in paint order: by stacking context (floating nodes by
	 * z-index, overlays above them, each inside its owner's), then in tree order.
	 */
	public function hitTest(x:Float, y:Float, path:Array<Int>):Void {
		path.resize(0);
		hitBest = -1;
		if (count > 0) visitHit(0, x, y);
		var index = hitBest;
		while (index >= 0) {
			path.push(boxes[index].id);
			index = boxes[index].parent;
		}
		path.reverse();
	}

	var hitBest:Int = -1;

	function visitHit(index:Int, x:Float, y:Float):Void {
		var box = boxes[index];
		if (!box.visible || !inside(box.hitX, box.hitY, box.hitWidth, box.hitHeight, x, y)) return;
		if (box.hitChildren) {
			var child = index + 1;
			for (_ in 0...box.childCount) {
				visitHit(child, x, y);
				child += boxes[child].size;
			}
		}
		if (box.hitSelf && hitsSelf(box, x, y) && (hitBest < 0 || paintsAbove(index, hitBest))) hitBest = index;
	}

	/** Whether box `a` paints above box `b`. */
	function paintsAbove(a:Int, b:Int):Bool {
		var first = boxes[a], second = boxes[b];
		if (first.layerRank != second.layerRank) return first.layerRank > second.layerRank;
		if (first.floating != second.floating) return first.floating;
		if (first.ownerOrder != second.ownerOrder) return first.ownerOrder > second.ownerOrder;
		return a > b;
	}

	function hitsSelf(box:LayoutBox, x:Float, y:Float):Bool {
		if (!inside(box.worldX, box.worldY, box.worldWidth, box.worldHeight, x, y)
			|| !inside(box.clipX, box.clipY, box.clipWidth, box.clipHeight, x, y)) return false;
		var determinant = box.wa * box.wd - box.wb * box.wc;
		if (Math.abs(determinant) < 0.000001) return false;
		var dx = x - box.wtx, dy = y - box.wty;
		var localX = (box.wd * dx - box.wc * dy) / determinant - box.x;
		var localY = (box.wa * dy - box.wb * dx) / determinant - box.y;
		return inside(0.0, 0.0, box.width, box.height, localX, localY);
	}

	static inline function inside(rx:Float, ry:Float, rw:Float, rh:Float, x:Float, y:Float):Bool {
		return rw > 0.0 && rh > 0.0 && x >= rx && x <= rx + rw && y >= ry && y <= ry + rh;
	}

	/**
	 * Each node's hit-test pruning bounds and paint-order key: the union of the areas it and its descendants take the
	 * pointer in, and the rank of its stacking context.
	 */
	function resolveHitTesting():Void {
		for (index in 0...count) {
			var box = boxes[index];
			box.floatingChildren.resize(0);
			box.overlayChildren.resize(0);
			var node = box.node;
			box.id = node.id;
			box.childCount = node.children.length;
			box.hitSelf = node.hitSelf;
			box.hitChildren = node.hitChildren;
			box.zIndex = node.style.zIndex;
			var style = node.style;
			var parent = box.parent < 0 ? null : boxes[box.parent];
			if (parent == null) {
				box.owner = box.overlayOwner = index;
				box.floating = false;
			} else if (style.positioning == LayoutPositioning.Absolute) {
				box.floating = true;
				if (style.overlay) boxes[parent.overlayOwner].overlayChildren.push(index);
				else boxes[parent.owner].floatingChildren.push(index);
				box.owner = index;
				box.overlayOwner = style.overlay ? index : parent.overlayOwner;
			} else {
				box.floating = parent.floating;
				box.owner = parent.owner;
				box.overlayOwner = parent.overlayOwner;
			}
			worldBounds(index, current);
			box.worldX = current.x;
			box.worldY = current.y;
			box.worldWidth = current.width;
			box.worldHeight = current.height;
		}
		if (count == 0) return;
		nextRank = 0;
		rankContext(0);
		var index = count - 1;
		while (index >= 0) {
			var box = boxes[index];
			box.layerRank = boxes[box.owner].ownRank;
			box.ownerOrder = box.owner == 0 ? 0 : box.owner;
			// What it takes the pointer in itself, clipped, then what its descendants do.
			var x0 = 0.0, y0 = 0.0, x1 = 0.0, y1 = 0.0, any = false;
			if (box.hitSelf && box.visible) {
				x0 = Math.max(box.worldX, box.clipX);
				y0 = Math.max(box.worldY, box.clipY);
				x1 = Math.min(box.worldX + box.worldWidth, box.clipX + box.clipWidth);
				y1 = Math.min(box.worldY + box.worldHeight, box.clipY + box.clipHeight);
				any = x1 > x0 && y1 > y0;
			}
			if (box.hitChildren && box.visible) {
				var child = index + 1;
				for (_ in 0...box.childCount) {
					var childBox = boxes[child];
					if (childBox.hitWidth > 0.0 && childBox.hitHeight > 0.0) {
						if (!any) {
							x0 = childBox.hitX;
							y0 = childBox.hitY;
							x1 = childBox.hitX + childBox.hitWidth;
							y1 = childBox.hitY + childBox.hitHeight;
							any = true;
						} else {
							x0 = Math.min(x0, childBox.hitX);
							y0 = Math.min(y0, childBox.hitY);
							x1 = Math.max(x1, childBox.hitX + childBox.hitWidth);
							y1 = Math.max(y1, childBox.hitY + childBox.hitHeight);
						}
					}
					child += childBox.size;
				}
			}
			box.hitX = any ? x0 : 0.0;
			box.hitY = any ? y0 : 0.0;
			box.hitWidth = any ? x1 - x0 : 0.0;
			box.hitHeight = any ? y1 - y0 : 0.0;
			index--;
		}
	}

	var nextRank:Int = 0;

	/**
	 * Ranks the stacking context `owner` and those nested in it in paint order: floating children below zero z-index,
	 * the context itself, floating children at or above zero, then overlays; equal z-indexes keep tree order.
	 */
	function rankContext(owner:Int):Void {
		var box = boxes[owner];
		sortByZ(box.floatingChildren);
		for (child in box.floatingChildren) if (boxes[child].zIndex < 0) rankContext(child);
		box.ownRank = nextRank++;
		for (child in box.floatingChildren) if (boxes[child].zIndex >= 0) rankContext(child);
		sortByZ(box.overlayChildren);
		for (child in box.overlayChildren) rankContext(child);
	}

	/** A stable sort by z-index; the lists are short. */
	function sortByZ(list:Array<Int>):Void {
		for (i in 1...list.length) {
			var value = list[i], z = boxes[value].zIndex, j = i - 1;
			while (j >= 0 && boxes[list[j]].zIndex > z) {
				list[j + 1] = list[j];
				j--;
			}
			list[j + 1] = value;
		}
	}

	/** The text the node with ID `id` shows instead of its own, as last resolved; null when it shows all of it. */
	public function shownText(id:Int):Null<String> {
		var item = previousItems.get(id);
		return item == null ? null : item.shownText;
	}

	/**
	 * Writes the geometry of the node with ID `id` into its record at `record` of `output`, as the last solve placed it,
	 * and returns whether it is hidden. A node the last solve did not see gets zero geometry.
	 */
	public function writePlacement(id:Int, output:Bytes, record:Int):Bool {
		var index = indexOf.get(id);
		var box = index < 0 ? null : boxes[index];
		inline function float(offset:Int, value:Float):Void output.setFloat(record + offset, value);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_X_OFFSET, box == null ? 0.0 : box.x);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_Y_OFFSET, box == null ? 0.0 : box.y);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_WIDTH_OFFSET, box == null ? 0.0 : box.width);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_HEIGHT_OFFSET, box == null ? 0.0 : box.height);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_TEXT_X_OFFSET, box == null ? 0.0 : box.textX);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_TEXT_Y_OFFSET, box == null ? 0.0 : box.textY);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_TEXT_WIDTH_OFFSET, box == null ? 0.0 : box.textWidth);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_BASELINE_OFFSET, box != null && box.ownBaseline ? box.y
			+ box.baseline : Math.NaN);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_SCROLL_X_OFFSET, box == null ? 0.0 : box.scrollX);
		float(NativeKitUIConstants.NKUI_LAYOUT_NODE_SCROLL_Y_OFFSET, box == null ? 0.0 : box.scrollY);
		return box != null && box.hidden;
	}

	/**
	 * Sizes and arranges the subtree at `first`: the whole tree in the viewport, or a placed node's subtree at the
	 * `width` by `height` its placer gave it.
	 */
	function layOut(first:Int, width:Float, height:Float):Void {
		var end = first + boxes[first].size;
		var top = boxes[first];
		var index = end - 1;
		while (index >= first) fitAxis(index--, true);
		top.width = width >= 0.0 ? width : rootSize(top.node.style.width, top.fitWidth, top.minWidth, viewportWidth);
		for (index in first...end) assignAxis(index, true);
		for (index in first...end) {
			var box = boxes[index];
			if (box.text != null) layoutText(box);
			else if (box.measured && box.measuredWidth != box.width) measureContent(box, box.width);
		}
		index = end - 1;
		while (index >= first) fitAxis(index--, false);
		top.height = height >= 0.0 ? height : rootSize(top.node.style.height, top.fitHeight, top.minHeight,
			viewportHeight);
		for (index in first...end) assignAxis(index, false);
		index = end - 1;
		while (index >= first) arrange(index--);
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
			|| size.direction != paragraph.direction || size.tabWidth != paragraph.tabWidth
			|| size.truncation != node.truncation) {
			size.text = node.text;
			size.truncation = node.truncation;
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
			var before = size.shown;
			var session = this.session;
			size.shown = node.truncation != TextTruncation.None && session != null && node.text != null
				&& size.unwrappedWidth > box.textWidth + 0.5 ? truncate(node, box.textWidth, session) : null;
			if (session == null || box.textWidth <= 0.0) {
				size.height = size.lineHeight == null ? 0.0 : size.lineHeight;
				size.hasBaseline = false;
				size.baseline = 0.0;
			} else {
				session.measureText(size.shown != null ? size.shown : node.text, box.textWidth, node.peekTextStyle(),
					node.peekParagraphStyle(), measure);
				size.height = measure.height;
				size.hasBaseline = measure.hasBaseline;
				size.baseline = measure.baseline;
			}
			size.laidOutAt = box.textWidth;
			textSeconds += Sys.time() - started;
			if (size.shown != before) changedNodes.push(node.id);
		}
		box.textHeight = size.height;
	}

	/**
	 * The longest cut of `node`'s text, with an ellipsis where it is cut, no wider than `width` unwrapped: its start, or
	 * its start and end around the middle. Empty when not even the ellipsis fits.
	 */
	function truncate(node:LayoutNode, width:Float, session:LayoutSession):String {
		var textStyle = node.peekTextStyle(), paragraph = node.peekParagraphStyle();
		inline function fits(candidate:String):Bool {
			session.measureText(candidate, 0.0, textStyle, paragraph, measure);
			return measure.width <= width;
		}
		if (!fits(Ellipsis)) return "";
		var middle = node.truncation == TextTruncation.Middle;
		var document = new haxeon.editor.TextDocument(node.text);
		var total = document.codepointCount;
		inline function cut(count:Int):String {
			var prefix = middle ? (count + 1) >> 1 : count;
			return document.sliceCodepoints(0, prefix) + Ellipsis + document.sliceCodepoints(total - (count - prefix),
				total);
		}
		var low = 0, high = total;
		while (low < high) {
			var count = (low + high + 1) >> 1;
			if (fits(cut(count))) low = count;
			else high = count - 1;
		}
		return cut(low);
	}

	static inline final Ellipsis:String = "…";

	/** Nodes whose geometry or shown text the solves since the last `takeChanged` changed, which NativeKit must hear of. */
	final changedNodes:Array<Int> = [];

	/** Moves the IDs of the nodes whose geometry or shown text changed into `changes`. */
	internal function takeChanged(changes:Null<LayoutChanges>):Void {
		if (changes != null) for (id in changedNodes) changes.inputs.set(id, 0);
		changedNodes.resize(0);
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
		// Unconstrained by a parent, content is still bounded by the viewport, so content that takes all the room it is
		// given reports a width it can have.
		var minWidth = width > 0.0 ? width : limit(style.width, true, viewportWidth);
		var maxWidth = width > 0.0 ? width : limit(style.width, false, viewportWidth);
		var constraints = new LayoutMeasureConstraints(minWidth, maxWidth, limit(style.height, true, viewportHeight),
			limit(style.height, false, viewportHeight));
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
		if (result == null || !(result.width >= 0.0) || !(result.height >= 0.0) || !Math.isFinite(result.width)
			|| !Math.isFinite(result.height)) return;
		box.measured = true;
		box.measuredWidth = clampRange(result.width, minWidth, maxWidth);
		box.measuredHeight = clampRange(result.height, constraints.minHeight, constraints.maxHeight);
		box.contentBaseline = result.baseline;
		box.contentHasBaseline = result.hasBaseline;
	}

	/** An axis's least or greatest size for measuring content, no greater than `available` unless it is fixed. */
	static function limit(axis:LayoutAxis, minimum:Bool, available:Float):Float {
		var least = Math.min(Math.max(0.0, axis.min), available);
		return switch axis.sizing {
			case LayoutSizing.Fixed: axis.value;
			case LayoutSizing.Percent: minimum ? 0.0 : available;
			default: minimum ? least : axis.max > 0.0 ? Math.max(Math.min(axis.max, available), least) : available;
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
				// It brings its content to a parent that fits it, then takes its share of the size that gives, as a
				// percentage of an auto-sized box does in CSS; it can be made smaller, so it adds no minimum.
				fit = clamp(content, axis.min, axis.max);
				least = 0.0;
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
		var placer = box.node.placer;
		box.hidden = box.parent >= 0 && boxes[box.parent].hidden;
		if (placer != null && box.parent >= 0 && box.node.style.positioning == LayoutPositioning.Absolute) {
			var parent = boxes[box.parent];
			placement.x = placement.y = placement.width = placement.height = 0.0;
			placement.shown = true;
			placer.place(parent.width, parent.height, placement);
			if (!placement.shown) box.hidden = true;
			if (placement.width != box.width || placement.height != box.height)
				layOut(index, Math.max(0.0, placement.width), Math.max(0.0, placement.height));
			box.x = placement.x;
			box.y = placement.y;
		}
		if (box.parent >= 0) {
			var parent = boxes[box.parent];
			box.x += parent.x;
			box.y += parent.y;
		}
		box.scrollX = box.scrollY = 0.0;
		var scroll = box.node.scroll;
		if (scroll != null && box.parent >= 0) {
			// The content's extent: its own size, or as far as its children reach past it; they are still relative to it.
			var parent = boxes[box.parent];
			var style = box.node.style;
			var right = box.width, bottom = box.height;
			var child = index + 1;
			for (_ in 0...box.node.children.length) {
				var childBox = boxes[child];
				right = Math.max(right, childBox.x - style.padding.left + childBox.width);
				bottom = Math.max(bottom, childBox.y - style.padding.top + childBox.height);
				child += childBox.size;
			}
			locatingIn = index;
			scroll.settle(parent.width, parent.height, right, bottom, locator);
			box.scrollX = scroll.scrollX();
			box.scrollY = scroll.scrollY();
		}
		box.composeWorld(box.parent < 0 ? null : boxes[box.parent]);
		var anchor = box.node.anchor;
		if (anchor != null) placeAnchored(index, anchor);
	}

	final placement:LayoutPlacement = new LayoutPlacement();
	/** The scroll content being settled, whose descendants `locator` finds; their positions are still relative there. */
	var locatingIn:Int = -1;
	final locator:LayoutLocator;
	final placedLater:Array<Int> = [];
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
		var side = anchor.side;
		if (side != AnchorSide.Overlap) {
			// The opposite side when the node overflows on its own and the opposite has more room.
			var here = room(side, anchor.gap, left, top, right, bottom);
			if (anchor.flip && here < (vertical ? h : w)
				&& room(opposite(side), anchor.gap, left, top, right, bottom) > here)
				side = opposite(side);
		}
		// Sized from the anchor: at least as wide across its side as the anchor, at most as long as the room along it.
		var sizedWidth = w, sizedHeight = h;
		if (anchor.matchAnchor) {
			if (vertical || side == AnchorSide.Overlap) sizedWidth = Math.min(Math.max(w, target.width), right - left);
			else sizedHeight = Math.min(Math.max(h, target.height), bottom - top);
		}
		if (anchor.limitToRoom && side != AnchorSide.Overlap) {
			var space = Math.max(0.0, room(side, anchor.gap, left, top, right, bottom));
			if (vertical) sizedHeight = Math.min(sizedHeight, space);
			else sizedWidth = Math.min(sizedWidth, space);
		}
		if (sizedWidth != w || sizedHeight != h) {
			layOut(index, Math.max(0.0, box.width + sizedWidth - w), Math.max(0.0, box.height + sizedHeight - h));
			box.composeWorld(box.parent < 0 ? null : boxes[box.parent]);
			worldBounds(index, current);
			w = current.width;
			h = current.height;
		}
		if (side != AnchorSide.Overlap) {
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
	/** Whether a placer hid it or an ancestor. */
	public var hidden:Bool = false;
	/** How far a scroll container's content moves left and up, ahead of its own transform. */
	public var scrollX:Float = 0.0;
	public var scrollY:Float = 0.0;
	/** The world transform: x' = wa x + wc y + wtx, y' = wb x + wd y + wty. */
	public var wa:Float = 1.0;
	public var wb:Float = 0.0;
	public var wc:Float = 0.0;
	public var wd:Float = 1.0;
	public var wtx:Float = 0.0;
	public var wty:Float = 0.0;
	/** Resolution: whether it is drawn, the clip it inherits in viewport coordinates, and the one its children inherit. */
	public var visible:Bool = true;
	public var clipX:Float = 0.0;
	public var clipY:Float = 0.0;
	public var clipWidth:Float = 0.0;
	public var clipHeight:Float = 0.0;
	public var childClipX:Float = 0.0;
	public var childClipY:Float = 0.0;
	public var childClipWidth:Float = 0.0;
	public var childClipHeight:Float = 0.0;
	/** Hit testing: its bounds in viewport coordinates, the area it and its descendants take the pointer in, and its paint-order key. */
	public var worldX:Float = 0.0;
	public var worldY:Float = 0.0;
	public var worldWidth:Float = 0.0;
	public var worldHeight:Float = 0.0;
	public var hitX:Float = 0.0;
	public var hitY:Float = 0.0;
	public var hitWidth:Float = 0.0;
	public var hitHeight:Float = 0.0;
	public var floating:Bool = false;
	public var owner:Int = 0;
	public var overlayOwner:Int = 0;
	public var ownRank:Int = 0;
	public var layerRank:Int = 0;
	public var ownerOrder:Int = 0;
	/**
	 * What hit testing reads of the node, as it was when laid out: a reused frame keeps answering queries while the next
	 * build already edits the nodes.
	 */
	public var id:Int = 0;
	public var childCount:Int = 0;
	public var hitSelf:Bool = false;
	public var hitChildren:Bool = false;
	public var zIndex:Int = 0;
	public final floatingChildren:Array<Int> = [];
	public final overlayChildren:Array<Int> = [];

	public function new() {}

	public inline function setClip(x:Float, y:Float, width:Float, height:Float):Void {
		clipX = x;
		clipY = y;
		clipWidth = width;
		clipHeight = height;
	}

	/** Narrows its own clip to `bounds` on both axes. */
	public function intersectClip(bounds:AnchorRect, horizontal:Bool, vertical:Bool):Void {
		if (horizontal) {
			var right = Math.min(clipX + clipWidth, bounds.x + bounds.width);
			clipX = Math.max(clipX, bounds.x);
			clipWidth = Math.max(0.0, right - clipX);
		}
		if (vertical) {
			var bottom = Math.min(clipY + clipHeight, bounds.y + bounds.height);
			clipY = Math.max(clipY, bounds.y);
			clipHeight = Math.max(0.0, bottom - clipY);
		}
	}

	/** Narrows the clip its children inherit to `bounds` on the axes it clips. */
	public function intersectChildClip(bounds:AnchorRect, horizontal:Bool, vertical:Bool):Void {
		if (horizontal) {
			var right = Math.min(childClipX + childClipWidth, bounds.x + bounds.width);
			childClipX = Math.max(childClipX, bounds.x);
			childClipWidth = Math.max(0.0, right - childClipX);
		}
		if (vertical) {
			var bottom = Math.min(childClipY + childClipHeight, bounds.y + bounds.height);
			childClipY = Math.max(childClipY, bounds.y);
			childClipHeight = Math.max(0.0, bottom - childClipY);
		}
	}

	/** The parent's world transform, then this node's scroll offset, then its own transform about its origin. */
	public function composeWorld(parent:Null<LayoutBox>):Void {
		var style = node.style;
		var transform = style.transform;
		var originX = x + width * style.transformOriginX, originY = y + height * style.transformOriginY;
		var la = transform.a, lb = transform.b, lc = transform.c, ld = transform.d;
		var ltx = originX + transform.tx - (la * originX + lc * originY) - scrollX;
		var lty = originY + transform.ty - (lb * originX + ld * originY) - scrollY;
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

/** A node's geometry as a node record carries it, to tell when it changes. */
private class PlacedGeometry {
	var x:Float = 0.0;
	var y:Float = 0.0;
	var width:Float = 0.0;
	var height:Float = 0.0;
	var textX:Float = 0.0;
	var textY:Float = 0.0;
	var textWidth:Float = 0.0;
	var baseline:Float = 0.0;
	var hasBaseline:Bool = false;
	var scrollX:Float = 0.0;
	var scrollY:Float = 0.0;
	var hidden:Bool = false;

	public function new() {}

	public function matches(box:LayoutBox):Bool {
		return x == box.x && y == box.y && width == box.width && height == box.height && textX == box.textX
			&& textY == box.textY && textWidth == box.textWidth && hasBaseline == box.ownBaseline
			&& (!hasBaseline || baseline == box.baseline) && scrollX == box.scrollX && scrollY == box.scrollY
			&& hidden == box.hidden;
	}

	public function take(box:LayoutBox):Void {
		x = box.x;
		y = box.y;
		width = box.width;
		height = box.height;
		textX = box.textX;
		textY = box.textY;
		textWidth = box.textWidth;
		hasBaseline = box.ownBaseline;
		baseline = box.baseline;
		scrollX = box.scrollX;
		scrollY = box.scrollY;
		hidden = box.hidden;
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
	public var truncation:TextTruncation = TextTruncation.None;
	/** The cut text layout shows at the width it was last laid out at, or null for all of it. */
	public var shown:Null<String> = null;
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
