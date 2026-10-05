package haxeon.ui.debug;

import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiDirtyFlag;
import haxeon.ui.style.StyleDiff;

/** Per-submit style invalidation counts, compared by stable render-node ID. */
class UiStyleInvalidationMetrics {
	public final styleChangedNodes:Int;
	public final styleUnchangedNodes:Int;
	public final invalidationFlags:Int;
	public final layoutInvalidatedNodes:Int;
	public final textLayoutInvalidatedNodes:Int;
	public final paintInvalidatedNodes:Int;
	public final compositeInvalidatedNodes:Int;
	public final semanticsInvalidatedNodes:Int;
	public final hitGeometryInvalidatedNodes:Int;
	/** Whether the retained node topology changed since the previous submit. */
	public final treeChanged:Bool;
	/** Whether this frame requires a fresh native layout/render snapshot. */
	public final nativeLayoutRequired:Bool;

	function new(styleChangedNodes:Int, styleUnchangedNodes:Int, invalidationFlags:Int,
			layoutInvalidatedNodes:Int, textLayoutInvalidatedNodes:Int,
			paintInvalidatedNodes:Int, compositeInvalidatedNodes:Int,
			semanticsInvalidatedNodes:Int, hitGeometryInvalidatedNodes:Int,
			treeChanged:Bool, nativeLayoutRequired:Bool) {
		this.styleChangedNodes = styleChangedNodes;
		this.styleUnchangedNodes = styleUnchangedNodes;
		this.invalidationFlags = invalidationFlags;
		this.layoutInvalidatedNodes = layoutInvalidatedNodes;
		this.textLayoutInvalidatedNodes = textLayoutInvalidatedNodes;
		this.paintInvalidatedNodes = paintInvalidatedNodes;
		this.compositeInvalidatedNodes = compositeInvalidatedNodes;
		this.semanticsInvalidatedNodes = semanticsInvalidatedNodes;
		this.hitGeometryInvalidatedNodes = hitGeometryInvalidatedNodes;
		this.treeChanged = treeChanged;
		this.nativeLayoutRequired = nativeLayoutRequired;
	}

	/** Compares current nodes against the prior submitted tree without touching layout. */
	public static function compare(previous:Null<RenderNode>, current:Null<RenderNode>,
			?previousById:Map<Int, RenderNode>, ?currentById:Map<Int, RenderNode>, ?priorOverrides:Map<Int, RenderNode>):UiStyleInvalidationMetrics {
		var previousIndex = previousById == null ? new Map<Int, RenderNode>() : previousById;
		var currentIndex = currentById == null ? new Map<Int, RenderNode>() : currentById;
		previousIndex.clear();
		currentIndex.clear();
		if (previous != null)
			previous.walk(function(node) previousIndex.set(node.id.value, node));
		// Nodes rebuilt in place are in `previous` already, as their replacements: what they replaced is the real prior.
		if (priorOverrides != null)
			for (id => node in priorOverrides)
				previousIndex.set(id, node);

		var styleChangedNodes = 0;
		var styleUnchangedNodes = 0;
		var invalidationFlags = 0;
		var layoutInvalidatedNodes = 0;
		var textLayoutInvalidatedNodes = 0;
		var paintInvalidatedNodes = 0;
		var compositeInvalidatedNodes = 0;
		var semanticsInvalidatedNodes = 0;
		var hitGeometryInvalidatedNodes = 0;
		var treeChanged = previous == null && current != null;
		if (current != null)
			current.walk(function(node) {
				currentIndex.set(node.id.value, node);
				var prior = previousIndex.get(node.id.value);
				if (prior == null) {
					treeChanged = true;
				} else {
					var priorParent = prior.parent == null ? 0 : prior.parent.id.value;
					var currentParent = node.parent == null ? 0 : node.parent.id.value;
					if (priorParent != currentParent || prior.layout.visualKind != node.layout.visualKind ||
						!sameChildOrder(prior, node))
						treeChanged = true;
				}
				var diff = StyleDiff.compare(prior == null ? null : prior.computedStyle, node.computedStyle);
				node.syncRevisions(prior, diff);
				var flags = node.invalidationFlags;
				if (!diff.changed && flags == UiDirtyFlag.None) {
					styleUnchangedNodes++;
					return;
				}
				if (diff.changed)
					styleChangedNodes++;
				else
					styleUnchangedNodes++;
				invalidationFlags |= flags;
				if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsLayout)) layoutInvalidatedNodes++;
				if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsTextLayout)) textLayoutInvalidatedNodes++;
				if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsPaint)) paintInvalidatedNodes++;
				if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsComposite)) compositeInvalidatedNodes++;
				if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsSemantics)) semanticsInvalidatedNodes++;
				if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsHitGeometry)) hitGeometryInvalidatedNodes++;
			});
		if (previous != null)
			for (id in previousIndex.keys())
				if (!currentIndex.exists(id))
					treeChanged = true;

		if (treeChanged)
			invalidationFlags |= UiDirtyFlag.NeedsBuild;
		var nativeWork = UiDirtyFlag.NeedsBuild | UiDirtyFlag.NeedsTextLayout |
			UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsHitGeometry;
		var nativeLayoutRequired = (invalidationFlags & nativeWork) != 0;

		return new UiStyleInvalidationMetrics(styleChangedNodes, styleUnchangedNodes, invalidationFlags,
			layoutInvalidatedNodes, textLayoutInvalidatedNodes, paintInvalidatedNodes,
			compositeInvalidatedNodes, semanticsInvalidatedNodes, hitGeometryInvalidatedNodes,
			treeChanged, nativeLayoutRequired);
	}

	static function sameChildOrder(previous:RenderNode, current:RenderNode):Bool {
		if (previous.children.length != current.children.length)
			return false;
		for (index in 0...current.children.length)
			if (previous.children[index].id.value != current.children[index].id.value)
				return false;
		return true;
	}
}
