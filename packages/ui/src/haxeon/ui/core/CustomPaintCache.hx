package haxeon.ui.core;

import haxeon.ui.Canvas;
import haxeon.ui.DisplayList;
import haxeon.ui.LayoutSession;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.RenderNode;

/** The retained display lists of custom painters, by node id, and their bindings in the layout session. */
class CustomPaintCache {
	final entries:Map<Int, PaintEntry> = new Map();
	final stale:Array<Int> = [];

	/** Nodes whose painter ran in the last `update`. */
	public var painted(default, null) = 0;

	/** Nodes whose retained list was reused in the last `update`. */
	public var skipped(default, null) = 0;

	/** Visible painters with an empty paint plane in the last `update`. */
	public var empty(default, null) = 0;

	public function new() {}

	/**
		Paints or reuses the list of each node in `paintNodes`, binds it in `session`, and drops entries whose node is no
		longer a current painter in `currentNodes`. `onPaint` gets each painter's time, except for `uninspected`.
	**/
	public function update(session:LayoutSession, paintNodes:Array<RenderNode>, currentNodes:Map<Int, RenderNode>,
			onPaint:Null<Int->Float->Void>, uninspected:Null<RenderNode>):Void {
		painted = 0;
		skipped = 0;
		empty = 0;
		for (node in paintNodes) {
			var nodeId = node.id.value;
			var resolved = node.resolved;
			if (resolved != null && node.cachePolicy != CachePolicy.None) session.setCachePolicy(nodeId,
				node.cachePolicy);
			if (!node.hasPaintHandler() || resolved == null) {
				unbind(session, nodeId);
				continue;
			}
			if (resolved.visible && (resolved.width <= 0.0 || resolved.height <= 0.0)) empty++;
			// A hidden painter records nothing; do not cache that empty result as its content.
			// Keep any existing local list so it can be rebound when the node becomes visible.
			if (!resolved.visible || resolved.width <= 0.0 || resolved.height <= 0.0
				|| resolved.clipBounds.width <= 0.0 || resolved.clipBounds.height <= 0.0) {
				unbind(session, nodeId);
				continue;
			}
			var entry = entries.get(nodeId);
			if (entry == null) {
				entry = new PaintEntry();
				entries.set(nodeId, entry);
			}
			var contentReused = entry.list != null && canReuse(entry, node);
			if (contentReused) {
				if (entry.hasCommands) {
					if (!entry.bound) {
						session.setCustomPaint(nodeId, entry.list);
						entry.bound = true;
					}
					if (node.cachePolicy != CachePolicy.None) session.setCustomPaintCachePolicy(nodeId,
						node.cachePolicy);
				}
			} else {
				if (entry.canvas == null) {
					entry.canvas = new Canvas();
					entry.canvas.retainRectangles = true;
				}
				var canvas = entry.canvas;
				canvas.reset();
				var geometry:ResolvedLayoutItem = cast resolved;
				var inspectionStarted = onPaint == null || node == uninspected ? 0.0 : Sys.time();
				canvas.withState(function(target) {
					target.resetTransform();
					// Custom painters own only node-local pixels. Native layout and
					// compositing apply the resolved position, transform, and ancestor
					// clips when the retained list is embedded.
					target.clip(new Rect(0.0, 0.0, geometry.width, geometry.height));
					node.paintContent(target);
				});
				if (entry.list == null) entry.list = DisplayList.create();
				canvas.update(entry.list);
				if (onPaint != null && node != uninspected) onPaint(nodeId, Sys.time() - inspectionStarted);
				entry.hasCommands = entry.list.info().commandCount > 0;
				if (entry.hasCommands) {
					session.setCustomPaint(nodeId, entry.list);
					entry.bound = true;
				} else {
					session.clearCustomPaint(nodeId);
					entry.bound = false;
				}
				if (entry.hasCommands && node.cachePolicy != CachePolicy.None) session.setCustomPaintCachePolicy(nodeId,
					node.cachePolicy);
				entry.geometry = geometry;
				entry.key = node.retainedPaintKey();
				entry.revision = node.paintRevision;
				painted++;
			}
			updateComposite(session, entry, node);
			if (contentReused) skipped++;
		}
		stale.resize(0);
		for (nodeId in entries.keys()) if (!isCurrentPainter(currentNodes.get(nodeId))) stale.push(nodeId);
		for (nodeId in stale) {
			unbind(session, nodeId);
			entries.get(nodeId).release();
			entries.remove(nodeId);
		}
	}

	function updateComposite(session:LayoutSession, entry:PaintEntry, node:RenderNode):Void {
		var nodeId = node.id.value;
		if (!node.hasCompositePaint() || !entry.hasCommands) {
			if (entry.compositeBound) {
				session.clearCustomPaintComposite(nodeId);
				entry.compositeBound = false;
			}
			return;
		}
		var rebuilt = false;
		if (entry.compositeList == null || !canReuseComposite(entry, node)) {
			rebuilt = true;
			if (entry.compositeCanvas == null) entry.compositeCanvas = new Canvas();
			entry.compositeCanvas.reset();
			node.paintComposite(entry.compositeCanvas);
			if (entry.compositeList == null) entry.compositeList = DisplayList.create();
			entry.compositeCanvas.update(entry.compositeList);
			entry.compositeKey = node.retainedCompositeKey();
			entry.compositeGeometry = cast node.resolved;
		}
		if (entry.compositeList.info().commandCount > 0) {
			if (rebuilt || !entry.compositeBound) session.setCustomPaintComposite(nodeId, entry.compositeList);
			entry.compositeBound = true;
		} else if (entry.compositeBound) {
			session.clearCustomPaintComposite(nodeId);
			entry.compositeBound = false;
		}
	}

	/** Paints `nodeId` again next frame: a paint-only change its key does not capture. */
	public function invalidate(nodeId:Int):Void {
		var entry = entries.get(nodeId);
		if (entry != null) entry.key = null;
	}

	/** Paints every node again instead of reusing its list by key: the painters may be new code. */
	public function forgetKeys():Void {
		for (entry in entries) {
			entry.key = null;
			entry.compositeKey = null;
		}
	}

	/** Unbinds and releases every list. */
	public function dispose(session:LayoutSession):Void {
		session.clearCustomPaints();
		for (entry in entries) entry.release();
		entries.clear();
	}

	/** Matches the render traversal's eligibility checks. */
	static function isCurrentPainter(node:Null<RenderNode>):Bool {
		if (node == null || !node.hasPaintHandler()) return false;
		var geometry = node.resolved;
		return geometry != null && geometry.width > 0.0
			&& geometry.height > 0.0 && geometry.clipBounds.width > 0.0 && geometry.clipBounds.height > 0.0;
	}

	static function canReuse(entry:PaintEntry, node:RenderNode):Bool {
		var key = node.retainedPaintKey();
		if (key == null || entry.key == null || entry.key != key) return false;
		if (entry.revision != node.paintRevision) return false;
		return entry.geometry != null && node.resolved != null && samePaintGeometry(entry.geometry, node.resolved);
	}

	static function canReuseComposite(entry:PaintEntry, node:RenderNode):Bool {
		if (entry.compositeKey != node.retainedCompositeKey()) return false;
		return entry.compositeGeometry != null && node.resolved != null
			&& samePaintGeometry(entry.compositeGeometry, node.resolved);
	}

	/** Local custom display lists only depend on the size of their paint plane. */
	static function samePaintGeometry(left:ResolvedLayoutItem,
			right:ResolvedLayoutItem):Bool return left.width == right.width && left.height == right.height;

	function unbind(session:LayoutSession, nodeId:Int):Void {
		var entry = entries.get(nodeId);
		if (entry == null) return;
		if (entry.bound) {
			session.clearCustomPaint(nodeId);
			entry.bound = false;
		}
		if (entry.compositeBound) {
			session.clearCustomPaintComposite(nodeId);
			entry.compositeBound = false;
		}
	}
}

/** One painter's retained content list and its optional composite list. */
private class PaintEntry {
	public var canvas:Null<Canvas>;
	public var list:Null<DisplayList>;
	public var geometry:Null<ResolvedLayoutItem>;
	public var key:Null<String>;
	public var revision = 0;
	public var hasCommands = false;
	public var bound = false;
	public var compositeCanvas:Null<Canvas>;
	public var compositeList:Null<DisplayList>;
	public var compositeKey:Null<String>;
	public var compositeGeometry:Null<ResolvedLayoutItem>;
	public var compositeBound = false;

	public function new() {}

	public function release():Void {
		if (canvas != null) {
			canvas.reset();
			canvas.releaseRetained();
		}
		if (list != null) list.dispose();
		if (compositeCanvas != null) compositeCanvas.reset();
		if (compositeList != null) compositeList.dispose();
	}
}
