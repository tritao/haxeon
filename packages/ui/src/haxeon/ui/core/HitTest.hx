package haxeon.ui.core;

import haxeon.ui.core.RenderNode;
/** The path an event aimed at a node travels; layout picks the node under a point (`LayoutSession.hitTest`). */
class HitTest {
	/** The nodes from the root down to `node`: the path an event aimed at it travels. */
	public static function pathTo(node:Null<RenderNode>):Array<RenderNode> {
		if (node == null)
			return [];
		var result:Array<RenderNode> = [];
		var current:Null<RenderNode> = node;
		while (current != null) {
			var present:RenderNode = cast current;
			result.push(present);
			current = present.parent;
		}
		result.reverse();
		return result;
	}
}
