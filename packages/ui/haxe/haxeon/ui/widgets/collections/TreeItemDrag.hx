package haxeon.ui.widgets.collections;

import haxeon.ui.Point;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;

/** Pointer gesture shared by model-backed trees; application policy owns mutations. */
class TreeItemDrag implements haxeon.ui.animation.Animation {
	var tree:Null<TreeView>;
	var root:Null<RenderNode>;
	var revision:Null<haxeon.ui.core.State<Int>>;
	var x = 0.0;
	var y = 0.0;
	var hoverTime = 0.0;
	public final rows:Map<String, RenderNode> = [];
	var source:Null<String>;
	var destination:Null<String>;
	var pointer = -1;
	var startX = 0.0;
	var startY = 0.0;
	var dragging = false;
	var suppressClick = false;

	function rowAt(event:UiEvent):Null<String> {
		var point = new Point(event.x, event.y);
		for (key => row in rows) if (row.containsGlobalPoint(point)) return key;
		return null;
	}
	public function clear():Void {
		source = null; destination = null; pointer = -1; dragging = false;
	}
	public function dispose():Void {
		clear(); rows.clear(); tree = null; root = null; revision = null;
	}
	function repaint():Void {
		if (revision != null) revision.update(revision.value + 1);
	}
	public function advance(deltaSeconds:Float):Bool {
		var owner = tree, viewport = root, from = source;
		if (!dragging || owner == null || viewport == null || from == null) return false;
		var bounds = viewport.globalBounds();
		if (x >= bounds.x && x <= bounds.x + bounds.width && y >= bounds.y && y <= bounds.y + bounds.height) {
			var edge = Math.min(24.0, bounds.height / 4);
			var speed = y < bounds.y + edge ? -240.0 : y > bounds.y + bounds.height - edge ? 240.0 : 0.0;
			if (speed != 0 && owner.controller.scrollBy(0, speed * deltaSeconds)) repaint();
		}
		var target = rowAt(new UiEvent(UiEventKind.PointerMove, viewport.id, x, y));
		var canDrop = owner.canDropItem;
		var next = target != null && canDrop != null && canDrop(from, target) ? target : null;
		if (next != destination) {destination = next; hoverTime = 0; repaint();}
		hoverTime += deltaSeconds;
		if (destination != null && hoverTime >= 0.6 && owner.setExpanded(destination, true)) repaint();
		return true;
	}
	public function new() {}
	public function attach(root:RenderNode, tree:TreeView, context:BuildContext):Void {
		this.tree = tree; this.root = root;
		revision = context.state(context.id("tree-drag-revision"), 0);
		root.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || source != null) return;
			clear(); suppressClick = false;
			var key = rowAt(event);
			var canDrag:String->Bool = cast tree.canDragItem;
			if (key == null || canDrag == null || !canDrag(key)) return;
			source = key; pointer = event.pointerId; startX = event.x; startY = event.y;
			event.capturePointer(false);
		});
		root.on(UiEventKind.PointerMove, function(event) {
			if (source == null || pointer != event.pointerId) return;
			var dx = event.x - startX, dy = event.y - startY;
			if (!dragging && dx * dx + dy * dy < 36) return;
			if (!dragging) tree.select(source);
			dragging = true; suppressClick = true;
			var target = rowAt(event);
			var canDrop:(String, String)->Bool = cast tree.canDropItem;
			var next = target != null && canDrop != null && canDrop(source, target) ? target : null;
			if (destination != next) hoverTime = 0;
			destination = next; x = event.x; y = event.y;
			context.animations.track(this);
			event.preventDefault(); repaint();
		});
		root.on(UiEventKind.PointerUp, function(event) {
			if (event.button != 0 || source == null || pointer != event.pointerId) return;
			var from = source, target = rowAt(event), moved = dragging;
			clear(); event.releasePointer(); repaint();
			if (moved) {
				event.preventDefault();
				var canDrop:(String, String)->Bool = cast tree.canDropItem;
				var drop:(String, String)->Void = cast tree.onItemDrop;
				if (target != null && canDrop != null && drop != null && canDrop(from, target)) drop(from, target);
			}
		});
		root.on(UiEventKind.PointerCancel, function(event) {
			if (pointer != event.pointerId) return;
			clear(); event.releasePointer(); repaint();
		});
		root.on(UiEventKind.KeyDown, function(event) {
			if (source != null && event.key == UiKey.Escape) {
				clear(); suppressClick = true; event.cancelPointerCapture(); event.preventDefault(); repaint();
			}
		}, "capture");
		root.on(UiEventKind.Click, function(event) {
			if (suppressClick) { event.preventDefault(); event.stopImmediatePropagation(); }
		}, "capture");
		for (key => row in rows) if (destination == key) {
			var color = context.theme.tokens.accent;
			row.onPaint(function(canvas, geometry) {
				canvas.drawRectBorder(new Rect(0, 0, geometry.width, geometry.height), 2, color);
			}, "tree-drop-target:" + color.red + ":" + color.green + ":" + color.blue + ":" + color.alpha);
		}
	}
}
