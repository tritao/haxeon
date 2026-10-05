package nativekit.ui.widgets.docking;
import nativekit.ui.widgets.controls.TabsSelectionMode;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.TabItem;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.layout.SizedBox;
import nativekit.ui.widgets.layout.SplitOrientation;
import nativekit.ui.widgets.layout.SplitSide;
import nativekit.ui.widgets.layout.SplitView;
import nativekit.ui.widgets.layout.SplitViewOptions;
import nativekit.ui.widgets.text.Text;

import Color;
import FontCollection;
import LayoutAxis;
import LayoutPositioning;
import LayoutStyle;
import LayoutVisualKind;
import ParagraphStyle;
import Rect;
import TextLayout;
import TextStyle;
import TextWrap;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.State;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.core.View;
import nativekit.ui.docking.DockDropZone;
import nativekit.ui.docking.DockNode;
import nativekit.ui.docking.DockPanelDescriptor;
import nativekit.ui.docking.DockSplitAxis;
import nativekit.ui.docking.DockWorkspaceModel;
import nativekit.ui.widgets.docking.DockDropTarget;
import nativekit.ui.widgets.docking.DockTabDropTarget;
import nativekit.ui.widgets.docking.DockWorkspaceInteraction;
import nativekit.ui.widgets.controls.TabsOptions;
import nativekit.ui.theme.TextRole;
import nativekit.ui.style.StyleState;

/** Renders a DockWorkspaceModel using split panes, tab groups, and lazy panels. */
class DockWorkspace implements View {
	public static inline final DividerExtent = 8.0;
	public static inline final MinimumHorizontalExtent = 190.0;
	public final key:String;
	public final model:DockWorkspaceModel;
	public var interaction(default, null):DockWorkspaceInteraction;
	public final style:LayoutStyle;
	/** Available content height when the workspace sits below application chrome. */
	public var availableHeight:Null<Float> = null;
	/** Available content width when the workspace sits beside application chrome. */
	public var availableWidth:Null<Float> = null;
	final suppliedInteraction:Bool;
	final panelContents:Map<String, DockPanelContent>;

	public function new(key:String, model:DockWorkspaceModel,
			?panelContents:Array<DockPanelContent>, ?style:LayoutStyle,
			?interaction:DockWorkspaceInteraction) {
		if (key == null || key.length == 0 || model == null)
			throw "Dock workspaces require a stable key and model";
		this.key = key;
		this.model = model;
		suppliedInteraction = interaction != null;
		this.interaction = interaction == null ? new DockWorkspaceInteraction(model) : interaction;
		this.style = style == null ? defaultStyle() : style.copy();
		this.panelContents = new Map();
		if (panelContents != null)
			for (content in panelContents) {
				if (content == null || this.panelContents.exists(content.panelId))
					throw "Dock workspace panel content IDs must be unique";
				this.panelContents.set(content.panelId, content);
			}
	}

	public function build(context:BuildContext):RenderNode {
		var observed = context.buildProbe != null;
		var started = observed ? Sys.time() : 0.0;
		var mounted:State<DockWorkspaceMount> = context.resourceState(context.id("workspace-mount:" + key),
			function() { return new DockWorkspaceMount(model, interaction); },
			function(value) { value.dispose(); });
		var mount = mounted.value;
		mount.bind(model, suppliedInteraction ? interaction : null);
		mount.invalidate = function() context.commands.refresh();
		interaction = mount.interaction;
		interaction.beginFrame();
		var labelWidths:DockTextWidthCache = context.state(
			context.id("tab-label-width-cache"), new DockTextWidthCache()).value;
		var panelCache:DockPanelCache = context.state(
			context.id("panel-tree-cache:" + key), new DockPanelCache()).value;
		panelCache.retain(context);
		var paneCache:DockPanelCache = context.state(
			context.id("pane-tree-cache:" + key), new DockPanelCache()).value;
		paneCache.retain(context);
		var content = buildNode(model.root, context, [], "layout",
			availableWidth == null ? context.viewportWidth : availableWidth, availableHeight == null ? context.viewportHeight : availableHeight,
			labelWidths, panelCache, paneCache);
		var layout = new SizedBox("layout", content, LayoutAxis.grow(), LayoutAxis.grow());
		var root = new Column(key, [new KeyedView("content", layout)], style).build(context);
		// Includes the panels built inside it; subtract their own probes to get the chrome.
		if (observed)
			context.reportBuild("dock-workspace", 0.0, Sys.time() - started, root);
		return root;
	}

	function buildNode(node:DockNode, context:BuildContext, path:Array<Int>, nodeKey:String,
		availableWidth:Float, availableHeight:Float, labelWidths:DockTextWidthCache,
		panelCache:DockPanelCache, paneCache:DockPanelCache):View {
		if (node == null)
			return new Text("No dock layout");
		switch (node) {
			case DockNode.Empty: return new Text("No panels");
			case DockNode.Panel(panelId):
				return paneView([panelId], panelId, context, nodeKey, availableWidth, paneCache, function() {
					return targetView(panelId, buildTabs([panelId], panelId, context, nodeKey,
						availableWidth, labelWidths, panelCache));
				});
			case DockNode.Tabs(panelIds, activePanelId):
				var targetPanelId = activePanelId == null && panelIds != null && panelIds.length > 0
					? panelIds[0] : activePanelId;
				return paneView(panelIds, activePanelId, context, nodeKey, availableWidth, paneCache, function() {
					return targetPanelId == null ? buildTabs(panelIds, activePanelId, context, nodeKey,
						availableWidth, labelWidths, panelCache) : targetView(targetPanelId,
						buildTabs(panelIds, activePanelId, context, nodeKey, availableWidth, labelWidths,
							panelCache));
				});
			case DockNode.Split(axis, ratio, first, second):
				return buildSplit(axis, ratio, first, second, context, path, nodeKey,
					availableWidth, availableHeight, labelWidths, panelCache, paneCache);
		}
	}

	function buildTabs(panelIds:Array<String>, activePanelId:String,
		context:BuildContext, nodeKey:String, availableWidth:Float,
		labelWidths:DockTextWidthCache, panelCache:DockPanelCache):View {
		var items:Array<TabItem> = [];
		var visiblePanels:Array<DockPanelDescriptor> = [];
		if (panelIds != null)
			for (panelId in panelIds) {
				var descriptor = model.get(panelId);
				if (descriptor != null)
					visiblePanels.push(descriptor);
			}
		var selectedId = activePanelId == null && visiblePanels.length > 0 ? visiblePanels[0].id : activePanelId;
		if (visiblePanels.length == 1 &&
			visiblePanels[0].headerMode == nativekit.ui.docking.DockPanelHeaderMode.Content)
			return panelView(visiblePanels[0].id, availableWidth, panelCache);
		var allWidth = Math.max(0, visiblePanels.length - 1) * 4.0;
		var selectedWidth = allWidth;
		for (descriptor in visiblePanels) {
			var iconWidth = 20.0 + (descriptor.icon == null ? 0.0 : 14.0);
			var labelWidth = tabLabelWidth(descriptor.title, context, labelWidths);
			var badgeWidth = descriptor.badgeCount > 0 ? 28.0 + Std.string(descriptor.badgeCount).length * 6 : 0.0;
			var labelledWidth = badgeWidth + iconWidth + (descriptor.icon == null ? 0.0 : 8.0) + labelWidth;
			allWidth += labelledWidth;
			selectedWidth += descriptor.id == selectedId || descriptor.icon == null
				? labelledWidth : iconWidth + badgeWidth;
		}
		var showAllLabels = visiblePanels.length <= 1 || allWidth <= availableWidth;
		var showSelectedLabel = showAllLabels || selectedWidth <= availableWidth;
		for (descriptor in visiblePanels) {
			var item = new TabItem(descriptor.id, descriptor.title,
				panelView(descriptor.id, availableWidth, panelCache),
				descriptor.enabled, descriptor.icon,
				!showAllLabels && descriptor.icon != null &&
					(descriptor.id != selectedId || !showSelectedLabel) ? "" : null);
			item.badgeCount = descriptor.badgeCount;
			items.push(item);
		}
		var tabsStyle = new LayoutStyle();
		// The panel must follow its split pane even when the active tab's content
		// has a larger intrinsic width (for example, sensor property rows).
		tabsStyle.width = LayoutAxis.stretch();
		tabsStyle.height = LayoutAxis.grow();
		var options = new TabsOptions();
		options.style = tabsStyle;
		options.selectionMode = TabsSelectionMode.Controlled;
		options.onTabDragStart = function(panelId, event)
			interaction.beginTabDrag(panelId, event.pointerId, event.x, event.y);
		options.onTabDragMove = function(panelId, event)
			interaction.moveTabDrag(panelId, event.pointerId, event.x, event.y);
		options.onTabDragEnd = function(panelId, event)
			interaction.endTabDrag(panelId, event.pointerId, event.x, event.y);
		options.onTabDragCancel = function(panelId, event)
			interaction.cancelTabDrag(panelId, event.pointerId);
		options.onTabHeaderBuilt = function(panelId, node) {
			interaction.registerTabTarget(new DockTabDropTarget(panelId, node));
			var indicatorStyle = new LayoutStyle();
			indicatorStyle.width = LayoutAxis.grow();
			indicatorStyle.height = LayoutAxis.grow();
			indicatorStyle.positioning = LayoutPositioning.Absolute;
			indicatorStyle.zIndex = 2;
			var indicator = new RenderNode(context.id("tab-drop-indicator:" + panelId),
				LayoutVisualKind.Custom, indicatorStyle);
			indicator.hitTestSelf = false;
			var tabPreview = interaction.preview;
			var tabPreviewKey = tabPreview == null ? "none" :
				tabPreview.sourcePanelId + ":" + tabPreview.targetPanelId + ":" +
				Std.string(tabPreview.zone);
			indicator.onPaint(function(canvas, geometry) {
				var preview = interaction.preview;
				if (preview == null || preview.targetPanelId != panelId ||
					(preview.zone != DockDropZone.TabBefore && preview.zone != DockDropZone.TabAfter))
					return;
				var indicatorWidth = Math.max(2.0, Math.min(4.0, geometry.width * 0.08));
				var x = preview.zone == DockDropZone.TabBefore ? 0.0 :
					Math.max(0.0, geometry.width - indicatorWidth);
				canvas.fillRectIfPositive(new Rect(x, 0.0, indicatorWidth, geometry.height),
					Color.rgba(0.18, 0.52, 0.95, 0.9));
			}, "tab-drop-indicator:" + panelId + ":" + tabPreviewKey);
			node.add(indicator);
		};
		return nativekit.ui.widgets.controls.Tabs.withOptions(nodeKey, items, activePanelId, function(next) {
			model.activate(next);
		}, options);
	}

	function tabLabelWidth(label:String, context:BuildContext,
		labelWidths:DockTextWidthCache):Float {
		if (context.fonts == null) return label.length * 8.0;
		var style = context.resolveTextRole(TextRole.Button,
			TextStyleOverride.paragraph(TextWrap.None));
		return labelWidths.measure(context.fonts, label, style.textStyle, style.paragraphStyle);
	}

	function buildSplit(axis:DockSplitAxis, ratio:Float, first:DockNode, second:DockNode,
		context:BuildContext, path:Array<Int>, nodeKey:String,
		availableWidth:Float, availableHeight:Float, labelWidths:DockTextWidthCache,
		panelCache:DockPanelCache, paneCache:DockPanelCache):View {
		var firstPath = path.copy();
		firstPath.push(0);
		var secondPath = path.copy();
		secondPath.push(1);
		var horizontal = axis == DockSplitAxis.Horizontal;
		var available = horizontal ? availableWidth : availableHeight;
		if (available <= 0.0)
			available = 1000.0;
		var minimum = horizontal ? MinimumHorizontalExtent : 120.0;
		var divider = DividerExtent;
		var maximum = available - minimum - divider;
		if (maximum < minimum)
			maximum = minimum;
		var options = new SplitViewOptions();
		options.orientation = horizontal ? SplitOrientation.Horizontal : SplitOrientation.Vertical;
		options.resizableSide = SplitSide.Leading;
		options.extent = clamp(ratio * available, minimum, maximum);
		options.minimumExtent = minimum;
		options.maximumExtent = maximum;
		options.dividerExtent = divider;
		options.dividerVisualExtent = 3.0;
		options.onResize = function(next) {
			model.setSplitRatio(path, next / available);
		};
		var remaining = Math.max(0.0, available - options.extent - divider);
		var firstWidth = horizontal ? options.extent : availableWidth;
		var firstHeight = horizontal ? availableHeight : options.extent;
		var secondWidth = horizontal ? remaining : availableWidth;
		var secondHeight = horizontal ? availableHeight : remaining;
		return new SplitView(nodeKey,
			buildNode(first, context, firstPath, nodeKey + ":first", firstWidth, firstHeight,
				labelWidths, panelCache, paneCache),
			buildNode(second, context, secondPath, nodeKey + ":second", secondWidth, secondHeight,
				labelWidths, panelCache, paneCache),
			options);
	}

	/**
	 * One pane (its tab strip and active panel) as a retained subtree: rebuilt only when what it shows, or a hover,
	 * focus or state inside it, changed. The view is created lazily so a hit skips measuring labels and building tab items.
	 */
	function paneView(panelIds:Array<String>, activePanelId:Null<String>, context:BuildContext, nodeKey:String,
			availableWidth:Float, paneCache:DockPanelCache, create:Void->View):View
		return new DockPaneView(nodeKey, paneCacheKey(panelIds, activePanelId, context, nodeKey, availableWidth), create, paneCache,
			interaction);

	/** Null when the pane cannot be retained: its active panel has no cache key, so building it has effects the cache cannot see. */
	function paneCacheKey(panelIds:Array<String>, activePanelId:Null<String>, context:BuildContext, nodeKey:String,
			availableWidth:Float):Null<String> {
		if (panelIds == null || panelIds.length == 0)
			return null;
		var selected = activePanelId == null ? panelIds[0] : activePanelId;
		var content = panelContents.get(selected);
		var contentKey:Null<DockPanelCacheKeyBuilder> = content == null ? null : content.cacheKey;
		if (contentKey == null)
			return null;
		var text = nodeKey + "|width=" + availableWidth + "|style=" + context.styleRevision + "|viewport=" + context.viewportWidth + "x" +
			context.viewportHeight + "|drag=" + interaction.revision + "|active=" + selected;
		for (panelId in panelIds) {
			var descriptor = model.get(panelId);
			if (descriptor != null)
				text += "|" + panelId + ":" + descriptor.title + ":" + descriptor.badgeCount + ":" + Std.string(descriptor.icon) + ":" + descriptor.enabled + ":" + Std.string(descriptor.headerMode);
		}
		return text + "|content=" + contentKey();
	}

	function panelView(panelId:String, availableWidth:Float, panelCache:DockPanelCache):View {
		var descriptor = model.get(panelId);
		var content = panelContents.get(panelId);
		return descriptor == null ? new Text("Missing panel: " + panelId) : content == null ?
			new Text("Missing panel content: " + panelId) :
			new DockPanelView(descriptor, content, availableWidth, panelCache);
	}

	function targetView(targetPanelId:String, child:View):View
		return new DockDropTargetView(child, interaction, targetPanelId);

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.grow();
		return result;
	}

	static inline function clamp(value:Float, minimum:Float, maximum:Float):Float
		return value < minimum ? minimum : value > maximum ? maximum : value;
}

/** One subscription pair per mounted workspace, independent of rebuilt View instances. */
private class DockWorkspaceMount {
	public var model(default, null):DockWorkspaceModel;
	public var interaction(default, null):DockWorkspaceInteraction;
	public var invalidate:Null<Void->Void>;
	var stopModel:Null<Void->Void>;
	var stopInteraction:Null<Void->Void>;

	public function new(model:DockWorkspaceModel, interaction:DockWorkspaceInteraction) {
		this.model = model;
		this.interaction = interaction;
		subscribe();
	}

	public function bind(nextModel:DockWorkspaceModel,
			requestedInteraction:Null<DockWorkspaceInteraction>):Void {
		if (model == nextModel &&
			(requestedInteraction == null || interaction == requestedInteraction))
			return;
		unsubscribe();
		model = nextModel;
		interaction = requestedInteraction == null ? new DockWorkspaceInteraction(nextModel) : requestedInteraction;
		subscribe();
	}

	public function dispose():Void {
		unsubscribe();
		invalidate = null;
	}

	function subscribe():Void {
		var notify = function() { if (invalidate != null) invalidate(); };
		stopModel = model.listen(notify);
		stopInteraction = interaction.listen(notify);
	}

	function unsubscribe():Void {
		if (stopModel != null) stopModel();
		if (stopInteraction != null) stopInteraction();
		stopModel = null;
		stopInteraction = null;
	}
}

private class DockPanelView implements View {
	final descriptor:DockPanelDescriptor;
	final content:DockPanelContent;
	final availableWidth:Float;
	final panelCache:DockPanelCache;

	public function new(descriptor:DockPanelDescriptor, content:DockPanelContent,
			availableWidth:Float, panelCache:DockPanelCache) {
		this.descriptor = descriptor;
		this.content = content;
		this.availableWidth = availableWidth;
		this.panelCache = panelCache;
	}

	public function build(context:BuildContext):RenderNode {
		var cacheKeyBuilder:Null<DockPanelCacheKeyBuilder> = content.cacheKey;
		var cacheKey = cacheKeyBuilder == null ? null :
			cacheKeyBuilder() + "|style=" + context.styleRevision +
			"|viewport=" + context.viewportWidth + "x" + context.viewportHeight +
			"|width=" + availableWidth;
		var cached = cacheKey == null ? null : panelCache.entry(descriptor.id);
		var hitStarted = context.buildProbe != null ? Sys.time() : 0.0;
		if (cached != null && cached.key == cacheKey && cached.statesMatch(context)) {
			context.retainStateIds(cached.stateIds);
			var retained = context.currentRoot(cached.root);
			cached.replaceRoot(retained);
			context.claimRetainedTree(retained);
			retained.detach();
			if (context.buildProbe != null)
				context.reportBuild("panel-hit:" + descriptor.id, 0.0, Sys.time() - hitStarted, retained);
			return retained;
		}
		if (cached != null)
			cached.root.detach();
		var observed = context.buildProbe != null;
		var preparationStarted = observed ? Sys.time() : 0.0;
		var stateMarker = context.stateUsageMarker();
		var widthBuilder = content.buildWithWidth;
		var view = widthBuilder == null ? content.build(context) :
			widthBuilder(context, availableWidth);
		if (view == null)
			view = new Text("Panel returned no content: " + descriptor.id);
		var buildStarted = observed ? Sys.time() : 0.0;
		var root = context.withScope(new Key("panel:" + descriptor.id), function() {
			return view.build(context);
		});
		if (observed)
			context.reportBuild("panel:" + descriptor.id, buildStarted - preparationStarted,
				Sys.time() - buildStarted, root);
		if (cacheKey != null)
			{
				var usedStates = context.stateIdsUsedSince(stateMarker);
				panelCache.put(descriptor.id, cacheKey, root, usedStates, context.stateRevisions(usedStates));
			}
		return root;
	}
}

/** A retained pane: reuses the built tab strip and panel while its key and the interaction state inside it are unchanged. */
private class DockPaneView implements View {
	final key:String;
	final cacheKey:Null<String>;
	final create:Void->View;
	final cache:DockPanelCache;
	final interaction:DockWorkspaceInteraction;

	public function new(key:String, cacheKey:Null<String>, create:Void->View, cache:DockPanelCache, interaction:DockWorkspaceInteraction) {
		this.key = key;
		this.cacheKey = cacheKey;
		this.create = create;
		this.cache = cache;
		this.interaction = interaction;
	}

	public function build(context:BuildContext):RenderNode {
		var cached = cacheKey == null ? null : cache.entry(key);
		if (cached != null && cached.key == cacheKey && cached.statesMatch(context)) {
			context.retainStateIds(cached.stateIds);
			var retained = context.currentRoot(cached.root);
			cached.replaceRoot(retained);
			context.claimRetainedTree(retained);
			retained.detach();
			interaction.replay(cached.targets, cached.tabTargets);
			return retained;
		}
		if (cached != null)
			cached.root.detach();
		var stateMarker = context.stateUsageMarker();
		var targetMark = interaction.targetCount(), tabMark = interaction.tabTargetCount();
		var root = create().build(context);
		if (cacheKey != null) {
			var usedStates = context.stateIdsUsedSince(stateMarker);
			cache.put(key, cacheKey, root, usedStates, context.stateRevisions(usedStates), interaction.targetsSince(targetMark),
				interaction.tabTargetsSince(tabMark));
		}
		return root;
	}
}

private class DockPanelCache {
	final entries:Map<String, DockPanelCacheEntry>;

	public function new()
		entries = new Map();

	public function entry(panelId:String):Null<DockPanelCacheEntry>
		return entries.get(panelId);

	public function put(panelId:String, key:String, root:RenderNode, stateIds:Array<Int>,
			stateRevisions:Array<Int>, ?targets:Array<DockDropTarget>, ?tabTargets:Array<DockTabDropTarget>):Void {
		var previous = entries.get(panelId);
		if (previous != null && previous.root != root)
			previous.root.detach();
		entries.set(panelId, new DockPanelCacheEntry(key, root, stateIds, stateRevisions, targets, tabTargets));
	}

	public function retain(context:BuildContext):Void {
		for (entry in entries)
			context.retainStateIds(entry.stateIds);
	}
}

private class DockPanelCacheEntry {
	public final key:String;
	public var root(default, null):RenderNode;
	public final stateIds:Array<Int>;
	/** Drop targets the build registered; a hit replays them because the interaction forgets them every frame. */
	public final targets:Array<DockDropTarget>;
	public final tabTargets:Array<DockTabDropTarget>;
	final stateRevisions:Array<Int>;

	public function new(key:String, root:RenderNode, stateIds:Array<Int>, stateRevisions:Array<Int>, ?targets:Array<DockDropTarget>,
			?tabTargets:Array<DockTabDropTarget>) {
		this.key = key;
		this.root = root;
		this.stateIds = stateIds == null ? [] : stateIds.copy();
		this.stateRevisions = stateRevisions == null ? [] : stateRevisions.copy();
		this.targets = targets == null ? [] : targets;
		this.tabTargets = tabTargets == null ? [] : tabTargets;
	}

	/** A self-updating widget at the root of the subtree was rebuilt in place; keep the replacement. */
	public function replaceRoot(next:RenderNode):Void
		root = next;

	public function statesMatch(context:BuildContext):Bool {
		// A widget inside the panel changed its own state (a select opening, a section toggling). The
		// panel's cache key knows nothing about that, so the built tree is stale and must be rebuilt.
		var current = context.stateRevisions(stateIds);
		for (index in 0...current.length)
			if (current[index] != stateRevisions[index])
				return false;
		var mask = StyleState.Hovered | StyleState.Pressed | StyleState.Focused;
		var result = true;
		context.currentRoot(root).walk(function(node) {
			if (node.recordsInteraction && (node.states & mask) != (context.interactionStates.get(node.id) & mask))
				result = false;
		});
		return result;
	}
}

private class DockDropTargetView implements View {
	final child:View;
	final interaction:DockWorkspaceInteraction;
	final targetPanelId:String;

	public function new(child:View, interaction:DockWorkspaceInteraction,
			targetPanelId:String) {
		if (child == null || interaction == null || targetPanelId == null)
			throw "Dock drop target views require a child, interaction, and target";
		this.child = child;
		this.interaction = interaction;
		this.targetPanelId = targetPanelId;
	}

	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		interaction.registerTarget(new DockDropTarget(targetPanelId, node));
		var activePreview = interaction.preview;
		if (activePreview != null && activePreview.targetPanelId == targetPanelId) {
			var previewStyle = new LayoutStyle();
			previewStyle.width = LayoutAxis.grow();
			previewStyle.height = LayoutAxis.grow();
			previewStyle.positioning = LayoutPositioning.Absolute;
			previewStyle.zIndex = 2;
			var previewNode = new RenderNode(context.id("drop-preview:" + targetPanelId),
				LayoutVisualKind.Custom, previewStyle);
			previewNode.setStyleIdentity("dock-drop-preview", targetPanelId);
			previewNode.hitTestSelf = false;
			var previewKey = activePreview.sourcePanelId + ":" + activePreview.targetPanelId + ":" +
				Std.string(activePreview.zone);
			previewNode.onPaint(function(canvas, geometry) {
				var preview = interaction.preview;
				if (preview == null || preview.targetPanelId != targetPanelId)
					return;
				canvas.fillRectIfPositive(previewRect(preview.zone, geometry.width, geometry.height),
					Color.rgba(0.18, 0.52, 0.95, 0.22));
			}, "dock-drop-preview:" + previewKey);
			node.add(previewNode);
		}
		return node;
	}

	static function previewRect(zone:DockDropZone, width:Float, height:Float):Rect {
		return switch (zone) {
			case DockDropZone.Center: new Rect(width * 0.2, height * 0.2, width * 0.6, height * 0.6);
			case DockDropZone.TabBefore: new Rect(0.0, 0.0, Math.max(3.0, width * 0.08), height);
			case DockDropZone.TabAfter: new Rect(Math.max(0.0, width * 0.92), 0.0,
				Math.max(3.0, width * 0.08), height);
			case DockDropZone.Left: new Rect(0.0, 0.0, width * 0.25, height);
			case DockDropZone.Right: new Rect(width * 0.75, 0.0, width * 0.25, height);
			case DockDropZone.Top: new Rect(0.0, 0.0, width, height * 0.25);
			case DockDropZone.Bottom: new Rect(0.0, height * 0.75, width, height * 0.25);
		};
	}
}

/** Bounded measured-width cache for tab labels during repeated workspace builds. */
private class DockTextWidthCache {
	static inline var MAX_ENTRIES:Int = 128;
	var fonts:Null<FontCollection>;
	final widths:Map<String, Float>;
	var entryCount:Int;

	public function new() {
		fonts = null;
		widths = new Map();
		entryCount = 0;
	}

	public function measure(fonts:FontCollection, label:String, textStyle:TextStyle,
		paragraphStyle:ParagraphStyle):Float {
		if (this.fonts != fonts) {
			this.fonts = fonts;
			widths.clear();
			entryCount = 0;
		}
		var key = cacheKey(label, textStyle, paragraphStyle);
		var cached:Null<Float> = widths.get(key);
		if (cached != null)
			return cached;
		var layout = TextLayout.createStyled(fonts, label, 100000.0, textStyle, paragraphStyle);
		var width = layout.measure().width;
		layout.dispose();
		if (entryCount >= MAX_ENTRIES) {
			widths.clear();
			entryCount = 0;
		}
		widths.set(key, width);
		entryCount++;
		return width;
	}

	static function cacheKey(label:String, textStyle:TextStyle,
		paragraphStyle:ParagraphStyle):String {
		return label.length + ":" + label + "|font=" + Std.string(textStyle.font) +
			"|size=" + textStyle.fontSize + "|letter=" + textStyle.letterSpacing +
			"|wrap=" + Std.string(paragraphStyle.wrap) +
			"|align=" + Std.string(paragraphStyle.alignment) +
			"|line=" + (paragraphStyle.lineHeight == null ? "none" : Std.string(paragraphStyle.lineHeight)) +
			"|direction=" + Std.string(paragraphStyle.direction);
	}
}
