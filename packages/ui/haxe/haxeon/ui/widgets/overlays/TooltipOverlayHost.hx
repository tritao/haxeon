package haxeon.ui.widgets.overlays;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Lift tooltip surfaces out of clipped stacking contexts before layout. */
class TooltipOverlayHost implements View {
	final content:View;
	public function new(content:View) this.content = content;
	public function build(context:BuildContext):RenderNode {
		var lifted = context.lazyState(context.id("lifted-tooltips"),
			function() return new Array<{tip:RenderNode, anchor:RenderNode}>()).value;
		// Retained anchors must recover their tooltip before being reused.
		for (entry in lifted) entry.anchor.add(entry.tip.detach());
		lifted.resize(0);
		var root = content.build(context);
		var tooltips:Array<RenderNode> = [];
		root.walk(function(node) {
			if (node.styleType == "tooltip") tooltips.push(node);
		});
		for (tip in tooltips) {
			lifted.push({tip: tip, anchor: tip.parent});
			root.add(tip.detach());
		}
		// A self-updating widget (Tabs) rebuilds without the view, so what it made has tooltips still in their anchors while the
		// ones lifted by the build before stay in the overlay: both would carry one ID. Lift what a patch made in the place of
		// the tooltip it replaces.
		context.onPatched = function(patched) {
			var made:Array<RenderNode> = [];
			patched.walk(function(node) {
				if (node.styleType == "tooltip" && node.parent != root) made.push(node);
			});
			for (tip in made) {
				var anchor = tip.parent;
				if (anchor == null) continue;
				var position = -1;
				for (index in 0...lifted.length) if (lifted[index].tip.id.value == tip.id.value) { position = index; break; }
				var entry = {tip: tip, anchor: anchor};
				if (position < 0) {
					lifted.push(entry);
					root.add(tip.detach());
					continue;
				}
				var previous = lifted[position].tip;
				lifted[position] = entry;
				tip.detach();
				if (previous.parent == root) previous.replaceWith(tip); else root.add(tip);
			}
		};
		return root;
	}
}
