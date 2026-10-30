package haxeon.ui.debug;

import haxeon.ui.core.RenderNode;
import haxeon.ui.LayoutChanges;
import haxeon.ui.core.RenderTreeTopology;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.UiDirtyFlag;
import haxeon.ui.style.StyleDiff;

/** Per-submit style invalidation counts, compared by stable render-node ID. */
class UiStyleInvalidationMetrics {
	public var styleChangedNodes(default, null):Int;
	public var styleUnchangedNodes(default, null):Int;
	public var invalidationFlags(default, null):Int;
	public var layoutInvalidatedNodes(default, null):Int;
	public var textLayoutInvalidatedNodes(default, null):Int;
	public var paintInvalidatedNodes(default, null):Int;
	public var compositeInvalidatedNodes(default, null):Int;
	public var semanticsInvalidatedNodes(default, null):Int;
	public var hitGeometryInvalidatedNodes(default, null):Int;
	/** Whether the retained node topology changed since the previous submit. */
	public var treeChanged(default, null):Bool;
	/** Whether this frame requires a fresh native layout/render snapshot. */
	public var nativeLayoutRequired(default, null):Bool;

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

	/** Classifies current nodes against their prior submitted inputs. */
	public static function compare(previous:Null<RenderNode>, current:Null<RenderNode>,
			?previousById:Map<Int, RenderNode>, ?currentById:Map<Int, RenderNode>,
			?priorOverrides:Map<Int, RenderNode>, ?frame:UiStyleInvalidationFrame):UiStyleInvalidationMetrics {
		var previousIndex = previousById == null ? new Map<Int, RenderNode>() : previousById;
		var currentIndex = currentById == null ? new Map<Int, RenderNode>() : currentById;
		if (frame == null) {
			previousIndex.clear();
			if (previous != null) previous.walk(function(node) previousIndex.set(node.id.value, node));
		}
		currentIndex.clear();
		// Nodes rebuilt in place are in `previous` already, as their replacements: what they replaced is the real prior.
		if (priorOverrides != null)
			for (id => node in priorOverrides)
				previousIndex.set(id, node);

		var result = new UiStyleInvalidationMetrics(0, 0, 0, 0, 0, 0, 0, 0, 0,
			previous == null && current != null, false);
		var matched = current == null ? 0 : compareNode(current, previousIndex, currentIndex, frame, result);
		// Every visited prior was matched by ID; a smaller count means a node was removed.
		if (previous != null && !result.treeChanged && matched != previousIndex.size()) result.treeChanged = true;
		if (result.treeChanged) result.invalidationFlags |= UiDirtyFlag.NeedsBuild;
		var nativeWork = UiDirtyFlag.NeedsBuild | UiDirtyFlag.NeedsTextLayout |
			UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsHitGeometry;
		result.nativeLayoutRequired = (result.invalidationFlags & nativeWork) != 0;
		return result;
	}

	/** A direct walk avoids a visitor environment and boxed captured counters on every frame. */
	static function compareNode(node:RenderNode, previousIndex:Map<Int, RenderNode>, currentIndex:Map<Int, RenderNode>,
			frame:Null<UiStyleInvalidationFrame>, result:UiStyleInvalidationMetrics):Int {
		currentIndex.set(node.id.value, node);
		var prior = previousIndex.get(node.id.value);
		var content = node.layout.intrinsicContent;
		if (frame != null && !frame.preserveRevisions && content != null) {
			var version = content.getVersion();
			if (version != node.layout.measureVersion) {
				if (prior != null && prior.layout == node.layout) {
					prior = frame.context.comparisonPrior(prior);
					previousIndex.set(node.id.value, prior);
				}
				node.layout.measureVersion = version;
			}
		}
		if (prior == null) {
			result.treeChanged = true;
		} else {
			var priorParent = frame != null ? frame.topology.parent(node.id.value) : prior.parent == null ? 0 : prior.parent.id.value;
			var currentParent = node.parent == null ? 0 : node.parent.id.value;
			if (priorParent != currentParent || prior.layout.visualKind != node.layout.visualKind ||
				!sameChildOrder(prior, node, frame == null ? null : frame.topology))
				result.treeChanged = true;
		}
		if (frame != null && !frame.preserveRevisions && (prior == null || !frame.topology.sameChildren(node)))
			frame.changes.children.set(node.id.value, 0);
		var diff = StyleDiff.compare(prior == null ? null : prior.computedStyle, node.computedStyle);
		if (frame == null || !frame.preserveRevisions) node.syncRevisions(prior, diff);
		var flags = node.invalidationFlags;
		if (diff.changed)
			result.styleChangedNodes++;
		else
			result.styleUnchangedNodes++;
		result.invalidationFlags |= flags;
		if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsLayout)) result.layoutInvalidatedNodes++;
		if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsTextLayout)) result.textLayoutInvalidatedNodes++;
		if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsPaint)) result.paintInvalidatedNodes++;
		if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsComposite)) result.compositeInvalidatedNodes++;
		if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsSemantics)) result.semanticsInvalidatedNodes++;
		if (UiDirtyFlag.contains(flags, UiDirtyFlag.NeedsHitGeometry)) result.hitGeometryInvalidatedNodes++;
		var matched = prior == null ? 0 : 1;
		for (child in node.children) matched += compareNode(child, previousIndex, currentIndex, frame, result);
		return matched;
	}

	/** Classify announced edits made by geometry callbacks against their existing comparison priors. */
	public static function collectLayoutEdits(current:Map<Int, RenderNode>, priors:Map<Int, RenderNode>, changes:LayoutChanges):Void {
		for (id => prior in priors) {
			var node = current.get(id);
			if (node == null) continue;
			node.syncRevisions(prior, StyleDiff.compare(prior.computedStyle, node.computedStyle), true);
			node.syncSceneRevisions();
			if ((node.invalidationFlags & UiDirtyFlag.NativeInputs) != 0) changes.inputs.set(id, 0);
			if (!sameChildOrder(prior, node)) changes.children.set(id, 0);
		}
	}

	static function sameChildOrder(previous:RenderNode, current:RenderNode, ?topology:RenderTreeTopology):Bool {
		if (topology != null) return topology.sameChildren(current);
		if (previous.children.length != current.children.length)
			return false;
		for (index in 0...current.children.length)
			if (previous.children[index].id.value != current.children[index].id.value)
				return false;
		return true;
	}
}

/** Reused comparison inputs keep the frame visitor's capture fixed as the native boundary gains data. */
@:noCompletion
class UiStyleInvalidationFrame {
	public final context:BuildContext;
	public final changes:LayoutChanges;
	public var topology:RenderTreeTopology;
	public var preserveRevisions:Bool = false;

	public function new(context:BuildContext, changes:LayoutChanges, topology:RenderTreeTopology) {
		this.context = context;
		this.changes = changes;
		this.topology = topology;
	}
}
