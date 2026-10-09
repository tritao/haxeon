package haxeon.ui.widgets.collections;
import haxeon.ui.LayoutSizing;

import haxeon.ui.widgets.Icon;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Insets;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.PathBuilder;
import haxeon.ui.LineCap;
import haxeon.ui.LineJoin;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.PointerClickSequence;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityOrientation;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleStateUtil;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Spacer;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.icons.IconName;

/** Model-backed virtual tree with lazy visible-branch indexing and stable selection state. */
class TreeView implements View {
	public final key:String;
	public final model:TreeViewModel;
	public final viewportStyle:LayoutStyle;
	public final virtualization:VirtualizationPolicy;
	public var controller(default, null):ScrollController;
	public var materializedFirst(default, null):Int;
	public var materializedLast(default, null):Int;
	public var selectedKey(default, null):Null<String>;
	public var onSelectionChanged:Null<String->Void>;
	public var onItemActivated:Null<String->Void>;
	/** Primary row clicks, including repeated clicks on the selected item. */
	public var onItemClicked:Null<String->Int->Void>;
	/** Optional non-blocking hint used to draw expand controls without loading children. */
	public var hasChildrenHint:Null<String->Bool>;
	/** Toggle branches on every primary row click; otherwise toggle only on double-click. */
	public var expandOnSingleClick:Bool = false;
	public var onItemContextMenu:Null<String->UiEvent->Void>;
	public var onItemRename:Null<String->Void>;
	/** Optional row builder receiving the current expansion state. */
	public var itemBuilder:Null<(String, Bool)->View>;
	/** Return false to defer a requested expansion; toggles identify repeated pointer/activation intent. */
	public var onExpansionRequested:Null<(String, Bool, Bool)->Bool>;
	/** Called even when no visible branch needs collapsing, so pending requests can be canceled. */
	public var onCollapseAll:Null<Void->Void>;
	public var onExpandedChanged:Null<String->Bool->Void>;
	/** Horizontal indentation between tree hierarchy levels. */
	public var indentWidth:Float = 16.0;
	/** Draw vertical indentation guides through all rows inside expanded branches. */
	public var verticalGuidesOnly:Bool = false;
	/** Align leaf content in the disclosure column instead of reserving arrow space. */
	public var compactLeafIndent:Bool = false;

	final fallbackViewportHeight:Float;
	final expandedKeys:Map<String, Bool>;
	var expandedState:Null<State<Map<String, Bool>>>;
	var selectedState:Null<State<String>>;
	var expansionRevision:Int;
	var cachedModelRevision:Int;
	var cachedExpansionRevision:Int;
	var rootKeys:Array<String>;
	var rootOffsets:Array<Int>;
	var visibleCount:Int;
	var cachedEstimatedExtent:Float;
	var rootInitialExpansion:Map<String, Bool>;
	var expandedBranches:Map<String, TreeBranch>;
	var branchByKey:Map<String, TreeBranch>;
	var cachedUniform:Bool;
	var extentIndex:Null<VirtualExtentIndex>;
	var itemIds:Map<String, WidgetId>;

	public function new(key:String, model:TreeViewModel, ?viewportStyle:LayoutStyle,
			?controller:ScrollController, viewportHeight:Float = 300.0,
			?selectedKey:String, ?expandedKeys:Array<String>,
			?onSelectionChanged:String->Void, ?onItemActivated:String->Void,
			?onExpandedChanged:String->Bool->Void, ?virtualization:VirtualizationPolicy) {
		if (key == null || key.length == 0 || model == null || viewportHeight <= 0.0 ||
			!finite(viewportHeight) || (selectedKey != null && selectedKey.length == 0))
			throw "TreeView requires a stable key, model, and valid viewport height";
		this.key = key;
		this.model = model;
		this.viewportStyle = viewportStyle == null ? defaultViewportStyle(viewportHeight) :
			viewportStyle.copy();
		this.controller = controller == null ? new ScrollController() : controller;
		this.fallbackViewportHeight = viewportHeight;
		this.selectedKey = selectedKey;
		this.onSelectionChanged = onSelectionChanged;
		this.onItemActivated = onItemActivated;
		onItemClicked = null;
		hasChildrenHint = null;
		onItemContextMenu = null;
		onItemRename = null;
		this.onExpandedChanged = onExpandedChanged;
		this.virtualization = virtualization == null ? new VirtualizationPolicy() : virtualization;
		materializedFirst = 0;
		materializedLast = 0;
		this.expandedKeys = new Map();
		if (expandedKeys != null)
			for (expandedKey in expandedKeys) {
				if (expandedKey == null || expandedKey.length == 0)
					throw "TreeView expanded keys must be non-empty";
				this.expandedKeys.set(expandedKey, true);
			}
		expandedState = null;
		selectedState = null;
		expansionRevision = 0;
		cachedModelRevision = -1;
		cachedExpansionRevision = -1;
		rootKeys = [];
		rootOffsets = [0];
		visibleCount = 0;
		cachedEstimatedExtent = 0.0;
		rootInitialExpansion = new Map();
		expandedBranches = new Map();
		branchByKey = new Map();
		cachedUniform = false;
		extentIndex = null;
		itemIds = new Map();
	}

	/** Selects a visible node. Passing null clears selection without a callback. */
	public function select(nextKey:Null<String>):Bool {
		ensureTreeMetrics();
		if (nextKey != null && (nextKey.length == 0 || !branchByKey.exists(nextKey)))
			throw "TreeView selection key is not visible";
		if (nextKey == selectedKey)
			return false;
		selectedKey = nextKey;
		updateSelectedState(nextKey);
		if (nextKey != null && onSelectionChanged != null)
			onSelectionChanged(nextKey);
		return true;
	}

	/** Expands or collapses a visible node. */
	public function setExpanded(nodeKey:String, expanded:Bool, toggle:Bool = false):Bool {
		ensureTreeMetrics();
		var entry = branchByKey.get(nodeKey);
		if (entry == null) return false;
		ensureEntryDetails(entry);
		if (!entry.hasChildren) return false;
		if (onExpansionRequested != null && !onExpansionRequested(nodeKey, expanded, toggle)) return true;
		if (entry.expanded == expanded) return false;
		var next = copyExpanded(expandedKeys);
		next.set(nodeKey, expanded);
		expandedKeys.clear();
		for (key in next.keys()) {
			var value:Bool = cast next.get(key);
			expandedKeys.set(key, value);
		}
		if (expandedState != null) {
			var state:State<Map<String, Bool>> = cast expandedState;
			state.update(expandedKeys);
		}
		if (expanded) expandBranch(entry); else collapseBranch(entry);
		expansionRevision++;
		cachedExpansionRevision = expansionRevision;
		updateVisibleMetrics();
		if (selectedKey != null && !branchByKey.exists(selectedKey)) {
			selectedKey = null;
			updateSelectedState(null);
		}
		if (onExpandedChanged != null)
			onExpandedChanged(nodeKey, expanded);
		return true;
	}

	/** Collapse known branches in one rebuild; optionally retain one open root level. */
	public function collapseAll(keepRootsExpanded:Bool = false):Bool {
		if (onCollapseAll != null) onCollapseAll();
		ensureTreeMetrics();
		var collapsed:Map<String, Bool> = [];
		for (key => value in expandedKeys) if (value) collapsed.set(key, true);
		for (branch in branchByKey) if (branch.expanded) collapsed.set(branch.key, true);
		var changed = false;
		var opened:Array<String> = [];
		if (keepRootsExpanded) for (key in rootKeys) {
			collapsed.remove(key);
			if (!expansionFor(key)) { opened.push(key); changed = true; }
			expandedKeys.set(key, true);
		}
		for (key in collapsed.keys()) { expandedKeys.set(key, false); changed = true; }
		if (!changed) return false;
		if (expandedState != null) {
			var state:State<Map<String, Bool>> = cast expandedState;
			state.update(expandedKeys);
		}
		expansionRevision++;
		ensureTreeMetrics();
		controller.jumpTo(controller.offsetX, 0);
		if (onExpandedChanged != null) {
			var notify:String->Bool->Void = cast onExpandedChanged;
			for (key in collapsed.keys()) notify(key, false);
			for (key in opened) notify(key, true);
		}
		return true;
	}

	public function toggleExpanded(nodeKey:String):Bool {
		ensureTreeMetrics();
		var entry = branchByKey.get(nodeKey);
		if (entry == null) return false;
		return setExpanded(nodeKey, !entry.expanded, true);
	}

	public function isExpanded(nodeKey:String):Bool {
		ensureTreeMetrics();
		var entry = branchByKey.get(nodeKey);
		return entry != null && entry.expanded;
	}

	/** Refreshes visible branches after model data changes, without rebuilding unrelated branches. */
	public function refreshBranches(nodeKeys:Array<String>, modelRevision:Int):Bool {
		if (nodeKeys == null || nodeKeys.length == 0 || extentIndex == null ||
			cachedExpansionRevision != expansionRevision || modelRevision != cachedModelRevision + 1)
			return false;
		for (nodeKey in nodeKeys)
			if (!branchByKey.exists(nodeKey)) return false;

		var metricsChanged = false;
		for (nodeKey in nodeKeys) {
			var branch = branchByKey.get(nodeKey);
			if (branch == null) return false;
			for (child in branch.children) removeBranch(child);
			branch.children.resize(0);
			branch.detailsKnown = false;
			if (branch.expanded) {
				populateExpandedBranch(branch);
				updateAncestorVisibleCounts(branch.parentBranch);
				metricsChanged = true;
			} else {
				ensureEntryDetails(branch);
			}
		}
		cachedModelRevision = modelRevision;
		if (metricsChanged) updateVisibleMetrics();
		if (selectedKey != null && !branchByKey.exists(selectedKey)) {
			selectedKey = null;
			updateSelectedState(null);
		}
		return true;
	}

	/** Scrolls a visible node to the top of the viewport. */
	public function scrollTo(nodeKey:String):Bool {
		ensureTreeMetrics();
		var index = indexOfKey(nodeKey);
		if (index == null)
			throw "TreeView scroll key is not visible";
		return controller.jumpTo(controller.offsetX, extentOffset(cast index));
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var clicks:State<PointerClickSequence> = context.state(context.id("click-sequence"), new PointerClickSequence());
			var expansion:State<Map<String, Bool>> = context.state(
				context.id("expanded-state"), expandedKeys);
			expandedState = expansion;
			if (expansion.value != expandedKeys) {
				expandedKeys.clear();
				for (storedKey in expansion.value.keys()) {
					var value:Bool = cast expansion.value.get(storedKey);
					expandedKeys.set(storedKey, value);
				}
				expansionRevision++;
			}
			var selection:State<String> = context.state(context.id("selected-key"),
				selectedKey == null ? "" : selectedKey);
			selectedState = selection;
			selectedKey = selection.value == "" ? null : selection.value;
			ensureTreeMetrics();
			if (selectedKey != null && !branchByKey.exists(selectedKey)) {
				selectedKey = null;
				selection.update("");
			}
			itemIds = new Map();

			var viewportHeight = controller.viewportHeight > 0.0 ? controller.viewportHeight :
				(viewportStyle.height.sizing == LayoutSizing.Fixed ? viewportStyle.height.value :
				fallbackViewportHeight);
			var window = requiredExtentIndex();
			measureWindowPreservingAnchor(window, viewportHeight);
			materializedFirst = window.first;
			materializedLast = window.last;
			var rowViews:Array<KeyedView> = [];
			if (window.count > 0) {
				rowViews.push(new KeyedView("before", new Spacer("before-spacer",
					LayoutAxis.grow(), LayoutAxis.fixed(window.startOffset(window.first)))));
				for (index in window.first...window.last) {
					var entry = entryAt(index);
					ensureEntryDetails(entry);
					var nodeKey = entry.key;
					var item = itemBuilder == null ? model.buildItem(nodeKey) : itemBuilder(nodeKey, entry.expanded);
					if (item == null)
						throw 'TreeView model returned null for key $nodeKey';
					var row = new TreeViewRow("row", nodeKey, item, entry, indentWidth, verticalGuidesOnly,
						compactLeafIndent, selectedKey == nodeKey,
						function() { select(nodeKey); },
						function() { if (entry.hasChildren) toggleExpanded(nodeKey); else if (onItemActivated != null) onItemActivated(nodeKey); },
						function() { toggleExpanded(nodeKey); },
						function(event) {
							var count = clicks.value.register(nodeKey, event);
							if (onItemClicked != null) onItemClicked(nodeKey, count);
							if (entry.hasChildren) {
								// Single-click expansion applies to every click, including the
								// second click recognized as part of a double-click sequence.
								if (expandOnSingleClick || count == 2) toggleExpanded(nodeKey);
							} else if (count == 2 && onItemActivated != null) onItemActivated(nodeKey);
						},
						function(event) { handleNodeKey(context, entry, event); },
						function(id) { itemIds.set(nodeKey, id); },
						function(event) {
							var handler = onItemContextMenu;
							if (handler != null) handler(nodeKey, event);
						});
					var slotKey = virtualization.recycleSlots ? 'slot:${index - window.first}' :
						'item:$nodeKey';
					rowViews.push(new KeyedView(slotKey, row));
				}
				rowViews.push(new KeyedView("after", new Spacer("after-spacer",
					LayoutAxis.grow(), LayoutAxis.fixed(window.totalExtent -
					window.startOffset(window.last)))));
			}

			var contentStyle = new LayoutStyle();
			contentStyle.width = LayoutAxis.grow();
			contentStyle.height = LayoutAxis.fixed(window.totalExtent);
			var content = new Column("tree-content", rowViews, contentStyle);
			var scroll = new ScrollView("viewport", content, viewportStyle,
				ScrollAxis.Vertical, controller);
			var root = new RenderNode(context.id("tree"), LayoutVisualKind.Box);
			root.layout.style.width = viewportStyle.width;
			root.layout.style.height = viewportStyle.height;
			var semantics = new Semantics(AccessibilityRole.Tree);
			semantics.setSize = visibleCount;
			semantics.orientation = AccessibilityOrientation.Vertical;
			semantics.actions = AccessibilityAction.ScrollForward | AccessibilityAction.ScrollBackward;
			root.semantics = semantics;
			var viewport = context.withScope(new Key("scroll-view"), function() return scroll.build(context));
			root.add(viewport);
			return root;
		});
	}

	function handleNodeKey(context:BuildContext, entry:TreeEntry, event:UiEvent):Void {
		var menu = onItemContextMenu;
		if (UiKey.isContextMenuRequest(event.key, event.modifiers) && menu != null) {
			select(entry.key);
			menu(entry.key, event);
			event.preventDefault();
			event.stopPropagation();
			return;
		}
		var rename = onItemRename;
		if (event.key == UiKey.F2 && rename != null) {
			event.preventDefault();
			rename(entry.key);
			return;
		}
		var nextKey:Null<String> = null;
		switch (event.key) {
			case UiKey.Up: nextKey = adjacentKey(entry.key, -1);
			case UiKey.Down: nextKey = adjacentKey(entry.key, 1);
			case UiKey.Home: nextKey = visibleCount == 0 ? null : entryAt(0).key;
			case UiKey.End: nextKey = visibleCount == 0 ? null : entryAt(visibleCount - 1).key;
			case UiKey.PageUp: nextKey = adjacentKey(entry.key, -visibleNodeCount());
			case UiKey.PageDown: nextKey = adjacentKey(entry.key, visibleNodeCount());
			case UiKey.Left:
				if (entry.hasChildren && entry.expanded) {
					event.preventDefault();
					setExpanded(entry.key, false);
					return;
				}
				// Also cancel a deferred expansion whose branch is still visually closed.
				if (entry.hasChildren) setExpanded(entry.key, false);
				if (entry.parentKey != null)
					nextKey = entry.parentKey;
			case UiKey.Right:
				if (entry.hasChildren && !entry.expanded) {
					event.preventDefault();
					setExpanded(entry.key, true);
					return;
				}
				if (entry.expanded && entry.hasChildren)
					nextKey = firstChildKey(entry.key);
			default: return;
		}
		if (nextKey == null || nextKey == entry.key)
			return;
		event.preventDefault();
		select(nextKey);
		scrollTo(nextKey);
		var target = itemIds.get(nextKey);
		if (target != null)
			context.requestFocus(target);
	}

	function adjacentKey(nodeKey:String, delta:Int):Null<String> {
		var current = indexOfKey(nodeKey);
		if (current == null || visibleCount == 0)
			return null;
		var currentIndex:Int = cast current;
		var next = Std.int(Math.max(0, Math.min(visibleCount - 1, currentIndex + delta)));
		return entryAt(next).key;
	}

	function firstChildKey(parentKey:String):Null<String> {
		var parent = indexOfKey(parentKey);
		if (parent == null || parent + 1 >= visibleCount)
			return null;
		var parentIndex:Int = cast parent;
		var child = entryAt(parentIndex + 1);
		return child.parentKey == parentKey ? child.key : null;
	}

	function indexOfKey(nodeKey:String):Null<Int> {
		var branch = branchByKey.get(nodeKey);
		if (branch == null) return null;
		var path:Array<TreeBranch> = [];
		var root = branch;
		while (root.parentBranch != null) {
			path.unshift(root);
			root = cast root.parentBranch;
		}
		if (root.rootIndex < 0 || root.rootIndex >= rootKeys.length) return null;
		var index = rootOffsets[root.rootIndex];
		for (node in path) {
			var parent = node.parentBranch;
			if (parent == null) return null;
			index++;
			for (siblingIndex in 0...node.siblingIndex)
				index += parent.children[siblingIndex].visibleCount;
		}
		return index;
	}

	function visibleNodeCount():Int {
		if (extentIndex == null)
			return 1;
		var window = requiredExtentIndex();
		if (window.count == 0)
			return 1;
		return Std.int(Math.max(1.0, Math.ceil(window.viewportExtent /
			Math.max(1.0, window.extentAt(window.first)))));
	}

	function ensureTreeMetrics():Void {
		var modelRevision = model.revision();
		if (cachedModelRevision == modelRevision && cachedExpansionRevision == expansionRevision &&
			extentIndex != null)
			return;
		var estimatedExtent = model.estimatedExtent();
		if (estimatedExtent <= 0.0 || !finite(estimatedExtent))
			throw "TreeView estimated extent must be finite and positive";
		cachedUniform = model.extentIsUniform();
		var rootCount = model.rootCount();
		if (rootCount < 0)
			throw "TreeView root count must be non-negative";
		var roots:Array<String> = [];
		var rootMetadata = model.rootRange(0, rootCount);
		if (rootMetadata == null || rootMetadata.length != rootCount)
			throw "TreeView root range returned an invalid number of entries";
		rootInitialExpansion = new Map();
		for (index in 0...rootCount) {
			var metadata = rootMetadata[index];
			if (metadata == null)
				throw 'TreeView root $index returned null metadata';
			var rootKey = metadata.key;
			if (rootKey == null || rootKey.length == 0)
				throw 'TreeView root $index has an empty key';
			rootInitialExpansion.set(rootKey, metadata.initiallyExpanded);
			roots.push(rootKey);
		}

		cachedEstimatedExtent = estimatedExtent;
		rootKeys = roots;
		rootOffsets = [0];
		expandedBranches = new Map();
		branchByKey = new Map();
		visibleCount = 0;
		for (rootIndex in 0...roots.length) {
			var rootKey = roots[rootIndex];
			var branch = buildBranch(rootKey, null, 0, [], rootIndex < roots.length - 1,
				rootIndex, rootIndex, null);
			expandedBranches.set(rootKey, branch);
			visibleCount += branch.visibleCount;
			rootOffsets.push(visibleCount);
		}

		cachedModelRevision = modelRevision;
		cachedExpansionRevision = expansionRevision;
		extentIndex = new VirtualExtentIndex(visibleCount, estimatedExtent,
			fallbackViewportHeight, controller.offsetY,
			virtualization.leadingOverscan, virtualization.trailingOverscan);
		if (selectedKey != null && !branchByKey.exists(selectedKey)) {
			selectedKey = null;
			updateSelectedState(null);
		}
	}

	function buildBranch(nodeKey:String, parentKey:Null<String>, depth:Int,
			guideContinuation:Array<Bool>, hasNextSibling:Bool, rootIndex:Int,
			siblingIndex:Int, parentBranch:Null<TreeBranch>):TreeBranch {
		if (branchByKey.exists(nodeKey))
			throw 'TreeView contains a duplicate visible key $nodeKey';
		var branch = new TreeBranch(nodeKey, parentKey, depth, cachedEstimatedExtent,
			guideContinuation, hasNextSibling, parentBranch, rootIndex, siblingIndex);
		branchByKey.set(nodeKey, branch);
		if (expansionFor(nodeKey)) populateExpandedBranch(branch);
		return branch;
	}

	function populateExpandedBranch(branch:TreeBranch):Void {
		var childCount = model.childCount(branch.key);
		if (childCount < 0)
			throw 'TreeView child count for ${branch.key} must be non-negative';
		branch.detailsKnown = true;
		branch.hasChildren = childCount > 0 || (hasChildrenHint != null && hasChildrenHint(branch.key));
		if (!branch.hasChildren) {
			branch.expanded = false;
			branch.visibleCount = 1;
			return;
		}
		branch.expanded = true;
		branch.children.resize(0);
		branch.visibleCount = 1;
		for (childIndex in 0...childCount) {
			var childKey = model.childKeyAt(branch.key, childIndex);
			if (childKey == null || childKey.length == 0)
				throw 'TreeView child ${branch.key}:$childIndex has an empty key';
			var childGuides = branch.guideContinuation.concat([verticalGuidesOnly || branch.hasNextSibling]);
			var child = buildBranch(childKey, branch.key, branch.depth + 1,
				childGuides, childIndex < childCount - 1, branch.rootIndex, childIndex, branch);
			branch.children.push(child);
			branch.visibleCount += child.visibleCount;
		}
	}

	function expandBranch(branch:TreeBranch):Void {
		populateExpandedBranch(branch);
		updateAncestorVisibleCounts(branch.parentBranch);
	}

	function collapseBranch(branch:TreeBranch):Void {
		for (child in branch.children) removeBranch(child);
		branch.children.resize(0);
		branch.expanded = false;
		branch.visibleCount = 1;
		updateAncestorVisibleCounts(branch.parentBranch);
	}

	function removeBranch(branch:TreeBranch):Void {
		for (child in branch.children) removeBranch(child);
		branchByKey.remove(branch.key);
	}

	function updateAncestorVisibleCounts(branch:Null<TreeBranch>):Void {
		var current = branch;
		while (current != null) {
			var count = 1;
			if (current.expanded) for (child in current.children) count += child.visibleCount;
			current.visibleCount = count;
			current = current.parentBranch;
		}
	}

	function updateVisibleMetrics():Void {
		visibleCount = 0;
		rootOffsets = [0];
		for (rootKey in rootKeys) {
			var branch = expandedBranches.get(rootKey);
			if (branch != null) visibleCount += branch.visibleCount;
			rootOffsets.push(visibleCount);
		}
		var viewportHeight = controller.viewportHeight > 0.0 ? controller.viewportHeight : fallbackViewportHeight;
		extentIndex = new VirtualExtentIndex(visibleCount, cachedEstimatedExtent,
			viewportHeight, controller.offsetY,
			virtualization.leadingOverscan, virtualization.trailingOverscan);
	}

	function entryAt(index:Int):TreeEntry {
		if (index < 0 || index >= visibleCount)
			throw "TreeView visible index is out of range";
		var low = 0;
		var high = rootKeys.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (rootOffsets[middle + 1] <= index)
				low = middle + 1;
			else
				high = middle;
		}
		var rootIndex = low;
		var rootKey = rootKeys[rootIndex];
		var rootBranch = expandedBranches.get(rootKey);
		var localIndex = index - rootOffsets[rootIndex];
		return branchEntryAt(rootBranch, localIndex);
	}

	function branchEntryAt(branch:TreeBranch, index:Int):TreeEntry {
		if (index == 0)
			return branch;
		var remaining = index - 1;
		for (child in branch.children) {
			if (remaining < child.visibleCount)
				return branchEntryAt(child, remaining);
			remaining -= child.visibleCount;
		}
		throw "TreeView branch index is out of range";
	}

	function ensureEntryDetails(entry:TreeEntry):Void {
		if (entry.detailsKnown)
			return;
		if (hasChildrenHint != null) {
			entry.hasChildren = hasChildrenHint(entry.key);
			entry.detailsKnown = true;
			return;
		}
		var childCount = model.childCount(entry.key);
		if (childCount < 0)
			throw 'TreeView child count for ${entry.key} must be non-negative';
		entry.hasChildren = childCount > 0;
		entry.detailsKnown = true;
	}

	function measureWindow(first:Int, last:Int):Void {
		if (extentIndex == null || cachedUniform)
			return;
		var indexMetrics = requiredExtentIndex();
		for (index in first...last) {
			var entry = entryAt(index);
			ensureEntryDetails(entry);
			var extent = model.extentAt(entry.key);
			if (extent <= 0.0 || !finite(extent))
				throw 'TreeView extent for ${entry.key} must be finite and positive';
			entry.extent = extent;
			indexMetrics.setExtent(index, extent);
		}
	}

	function measureWindowPreservingAnchor(window:VirtualExtentIndex,
			viewportHeight:Float):Void {
		window.update(viewportHeight, controller.offsetY, virtualization.leadingOverscan,
			virtualization.trailingOverscan);
		if (window.itemCount == 0)
			return;

		var anchorOffset = window.offset;
		var anchorIndex = window.indexAtOffset(anchorOffset);
		var anchorLocalOffset = anchorOffset - window.startOffset(anchorIndex);
		measureWindow(window.first, window.last);
		window.update(viewportHeight, controller.offsetY, virtualization.leadingOverscan,
			virtualization.trailingOverscan);
		measureWindow(window.first, window.last);
		window.update(viewportHeight, controller.offsetY, virtualization.leadingOverscan,
			virtualization.trailingOverscan);

		var correctedOffset = window.startOffset(anchorIndex) + anchorLocalOffset;
		if (Math.abs(correctedOffset - controller.offsetY) > 0.00001)
			controller.jumpTo(controller.offsetX, correctedOffset);
		window.update(viewportHeight, controller.offsetY, virtualization.leadingOverscan,
			virtualization.trailingOverscan);
	}

	function expansionFor(nodeKey:String):Bool {
		if (expandedKeys.exists(nodeKey))
			return expandedKeys.get(nodeKey);
		if (rootInitialExpansion.exists(nodeKey))
			return rootInitialExpansion.get(nodeKey);
		var expanded = model.initiallyExpanded(nodeKey);
		if (expanded)
			expandedKeys.set(nodeKey, true);
		return expanded;
	}

	function updateSelectedState(nextKey:Null<String>):Void {
		if (selectedState == null)
			return;
		var state:State<String> = cast selectedState;
		state.update(nextKey == null ? "" : nextKey);
	}

	function extentOffset(index:Int):Float {
		if (extentIndex == null)
			return 0.0;
		var window = requiredExtentIndex();
		return window.startOffset(index);
	}

	function requiredExtentIndex():VirtualExtentIndex {
		var result = extentIndex;
		if (result == null)
			throw "TreeView extent metrics are not initialized";
		return result;
	}

	static function copyExpanded(source:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = new Map();
		for (key in source.keys()) {
			var value:Bool = cast source.get(key);
			result.set(key, value);
		}
		return result;
	}

	static function defaultViewportStyle(height:Float):LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.fixed(height);
		return result;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

private class TreeEntry {
	public final key:String;
	public final parentKey:Null<String>;
	public final depth:Int;
	public var hasChildren:Bool;
	public var expanded:Bool;
	public var extent:Float;
	public var detailsKnown:Bool;
	public final guideContinuation:Array<Bool>;
	public final hasNextSibling:Bool;

	public function new(key:String, parentKey:Null<String>, depth:Int,
			hasChildren:Bool, expanded:Bool, extent:Float, detailsKnown:Bool = true,
			?guideContinuation:Array<Bool>, hasNextSibling:Bool = false) {
		this.key = key;
		this.parentKey = parentKey;
		this.depth = depth;
		this.hasChildren = hasChildren;
		this.expanded = expanded;
		this.extent = extent;
		this.detailsKnown = detailsKnown;
		this.guideContinuation = guideContinuation == null ? [] : guideContinuation;
		this.hasNextSibling = hasNextSibling;
	}
}

private class TreeBranch extends TreeEntry {
	public final children:Array<TreeBranch>;
	public final rootIndex:Int;
	public final siblingIndex:Int;
	public var parentBranch:Null<TreeBranch>;
	public var visibleCount:Int;

	public function new(key:String, parentKey:Null<String>, depth:Int, extent:Float,
			guideContinuation:Array<Bool>, hasNextSibling:Bool,
			parentBranch:Null<TreeBranch>, rootIndex:Int, siblingIndex:Int) {
		super(key, parentKey, depth, false, false, extent, false,
			guideContinuation, hasNextSibling);
		this.parentBranch = parentBranch;
		this.rootIndex = rootIndex;
		this.siblingIndex = siblingIndex;
		children = [];
		visibleCount = 1;
	}
}

private class TreeViewRow implements View {
	final key:String;
	final itemKey:String;
	final child:View;
	final entry:TreeEntry;
	final indentWidth:Float;
	final verticalGuidesOnly:Bool;
	final compactLeafIndent:Bool;
	final selected:Bool;
	final onSelect:Void->Void;
	final onActivate:Void->Void;
	final onToggle:Void->Void;
	final onClick:UiEvent->Void;
	final onKey:UiEvent->Void;
	final onBuilt:WidgetId->Void;
	final onContextMenu:UiEvent->Void;

	public function new(key:String, itemKey:String, child:View, entry:TreeEntry, indentWidth:Float,
			verticalGuidesOnly:Bool, compactLeafIndent:Bool, selected:Bool,
			onSelect:Void->Void, onActivate:Void->Void, onToggle:Void->Void,
			onClick:UiEvent->Void, onKey:UiEvent->Void, onBuilt:WidgetId->Void, onContextMenu:UiEvent->Void) {
		this.key = key;
		this.itemKey = itemKey;
		this.child = child;
		this.entry = entry;
		this.indentWidth = indentWidth;
		this.verticalGuidesOnly = verticalGuidesOnly;
		this.compactLeafIndent = compactLeafIndent;
		this.selected = selected;
		this.onSelect = onSelect;
		this.onActivate = onActivate;
		this.onToggle = onToggle;
		this.onClick = onClick;
		this.onKey = onKey;
		this.onBuilt = onBuilt;
		this.onContextMenu = onContextMenu;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var id = context.id("tree-item");
			var flags = context.interactionStates.get(id);
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			style.height = LayoutAxis.fixed(entry.extent);
			style.direction = LayoutDirection.LeftToRight;
			style.childAlignY = LayoutAlignmentY.Center;
			style.childGap = 2.0;
			style.padding = new Insets(entry.depth * indentWidth, 0.0, 0.0, 0.0);
			style.background = selected ? context.theme.tokens.selectionHighlight :
				StyleStateUtil.contains(flags, StyleState.Hovered)
					? context.theme.tokens.selectionHover : Color.rgba(0.0, 0.0, 0.0, 0.0);
			var node = new RenderNode(id, LayoutVisualKind.Box, style);
			node.states = flags;
			node.focusable = true;
			var semantics = new Semantics(AccessibilityRole.TreeItem);
			semantics.label = itemKey;
			semantics.actions = AccessibilityAction.Activate | AccessibilityAction.Select;
			if (entry.hasChildren)
				semantics.actions |= entry.expanded ? AccessibilityAction.Collapse :
					AccessibilityAction.Expand;
			semantics.states |= AccessibilityState.Focusable;
			if (selected)
				semantics.states |= AccessibilityState.Selected;
			if (entry.expanded)
				semantics.states |= AccessibilityState.Expanded;
			semantics.positionInSet = entry.depth + 1;
			semantics.hierarchyLevel = entry.depth + 1;
			node.semantics = semantics;
			node.on(UiEventKind.Click, function(event) { if (event.button == 0) { onSelect(); onClick(event); } });
			node.on(UiEventKind.Activate, function(_) { onSelect(); onActivate(); });
			node.on(UiEventKind.KeyDown, onKey);
			node.on(UiEventKind.KeyRepeat, onKey);
			node.on(UiEventKind.PointerDown, function(event) {
				if (event.button == 1) {
					onSelect();
					onContextMenu(event);
					event.preventDefault();
					event.stopPropagation();
				}
			});
			if (entry.depth > 0) {
				var guides = new LayoutStyle();
				guides.positioning = LayoutPositioning.Absolute;
				guides.width = LayoutAxis.grow();
				guides.height = LayoutAxis.grow();
				var guideNode = new RenderNode(context.id("branch-guides"), LayoutVisualKind.Custom, guides);
				guideNode.hitTestSelf = false;
				var depth = entry.depth;
				var continuation = entry.guideContinuation;
				var hasNext = entry.hasNextSibling;
				var guideColor = context.theme.tokens.border;
				var guideKey = "tree-guide:" + depth + ":" + (hasNext ? "1" : "0") + ":" +
					(entry.hasChildren ? "branch" : "leaf") + ":";
				for (level in 1...depth)
					guideKey += continuation[level] ? "1" : "0";
				guideNode.onPaint(function(canvas, geometry) {
					var path = new PathBuilder();
					var hasSegments = false;
					var centerY = geometry.height * 0.5;
					for (level in 1...depth) if (continuation[level]) {
						var x = (level - 1) * indentWidth + indentWidth * 0.5;
						path.moveTo(x, 0.0).lineTo(x, geometry.height);
						hasSegments = true;
					}
					if (verticalGuidesOnly) {
						var x = (depth - 1) * indentWidth + indentWidth * 0.5;
						path.moveTo(x, 0.0).lineTo(x, geometry.height);
						hasSegments = true;
					} else {
						var x = (depth - 1) * indentWidth + indentWidth * 0.5;
						path.moveTo(x, 0.0).lineTo(x, hasNext ? geometry.height : centerY);
						path.moveTo(x, centerY).lineTo(x + 10.0, centerY);
						hasSegments = true;
					}
					if (hasSegments)
						canvas.strokeTransient(path.build(), guideColor, 1.0, LineCap.Butt, LineJoin.Miter);
				}, guideKey + ":" + indentWidth + ":" + (verticalGuidesOnly ? "vertical" : "branch") + ":" + guideColor.red + ":" + guideColor.green + ":" +
					guideColor.blue + ":" + guideColor.alpha);
				node.add(guideNode);
			}

			var disclosure:View = entry.hasChildren
				? new TreeDisclosure("disclosure-control", entry.expanded, entry.extent, onToggle)
				: new Spacer("disclosure-spacer", LayoutAxis.fixed(compactLeafIndent ? 0.0 : 20.0),
					LayoutAxis.fixed(entry.extent));
			node.add(context.withScope(new Key("disclosure"), function() return disclosure.build(context)));
			node.add(new KeyedView('item:$itemKey', child).build(context));
			onBuilt(node.id);
			return node;
		});
	}
}

private class TreeDisclosure implements View {
	final key:String;
	final expanded:Bool;
	final rowHeight:Float;
	final onToggle:Void->Void;

	public function new(key:String, expanded:Bool, rowHeight:Float, onToggle:Void->Void) {
		this.key = key;
		this.expanded = expanded;
		this.rowHeight = rowHeight;
		this.onToggle = onToggle;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var style = new LayoutStyle();
			style.width = LayoutAxis.fixed(20.0);
			style.height = LayoutAxis.fixed(rowHeight);
			style.direction = LayoutDirection.LeftToRight;
			style.childAlignX = LayoutAlignmentX.Center;
			style.childAlignY = LayoutAlignmentY.Center;
			style.padding = new Insets(0.0, 0.0, 0.0, 0.0);
			style.background = Color.rgba(0.0, 0.0, 0.0, 0.0);
			var node = new RenderNode(context.id("disclosure"), LayoutVisualKind.Box, style);
			node.focusable = true;
			var semantics = new Semantics(AccessibilityRole.Button, expanded ? "Collapse" : "Expand");
			semantics.actions = AccessibilityAction.Activate;
			node.semantics = semantics;
			var activate = function(event:UiEvent) {
				onToggle();
				event.stopPropagation();
			};
			node.on(UiEventKind.Click, function(event) {
				if (event.button == 0) activate(event);
			});
			node.on(UiEventKind.Activate, activate);
			node.add(new Icon("glyph", expanded ? IconName.ChevronDown : IconName.ChevronRight,
				16.0, context.theme.tokens.textPrimary).build(context));
			return node;
		});
	}
}
