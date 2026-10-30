package haxeon.ui.widgets.docking;
import haxeon.ui.widgets.controls.TabsSelectionMode;
import haxeon.ui.core.KeyHash;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.SizedBox;
import haxeon.ui.widgets.layout.SplitOrientation;
import haxeon.ui.widgets.layout.SplitSide;
import haxeon.ui.widgets.layout.SplitView;
import haxeon.ui.widgets.layout.SplitViewOptions;
import haxeon.ui.widgets.text.Text;

import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.Rect;
import haxeon.ui.TextLayout;
import haxeon.ui.TextStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.InteractionStateSnapshot;
import haxeon.ui.core.Key;
import haxeon.ui.core.KeyScope;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.docking.DockDropZone;
import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockPanelDescriptor;
import haxeon.ui.docking.DockSplitAxis;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.widgets.docking.DockDropTarget;
import haxeon.ui.widgets.docking.DockTabDropTarget;
import haxeon.ui.widgets.docking.DockWorkspaceInteraction;
import haxeon.ui.widgets.controls.TabsOptions;
import haxeon.ui.theme.TextRole;

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
	/** Optional fixed actions for a dock tab group, including single dock headers. */
	public var headerActions:Null<Array<String>->String->Null<View>> = null;
	/** Application-owned action state included in retained pane keys. */
	public var headerActionsRevision:String = "";
	/** Expand a matching group vertically without changing the persisted dock tree. */
	public var expandedGroup:Null<Array<String>> = null;
	/** Presentation-only suppression; preserves the model, split paths and saved layout. */
	public var hiddenPanels:Array<String> = [];
	final suppliedInteraction:Bool;
	final panelContents:Map<String, DockPanelContent>;
	/** Scratch for `fillPaneCacheKey`; read straight after it fills, before any other pane's key is built. */
	final paneKeyHash:KeyHash = new KeyHash();
	/** Where panel content is keyed while building: under the workspace, by panel ID (see DockPanelView). */
	var panelScope:Null<KeyScope> = null;

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
		panelScope = context.currentScope().child(new Key("dock-panels:" + key));
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
				if (hiddenPanels.indexOf(panelId) >= 0) return new haxeon.ui.widgets.layout.Spacer(nodeKey, LayoutAxis.fixed(0), LayoutAxis.fixed(0));
				return paneView([panelId], panelId, context, nodeKey, availableWidth, paneCache, function() {
					return targetView(panelId, buildTabs([panelId], panelId, context, nodeKey,
						availableWidth, labelWidths, panelCache));
				});
			case DockNode.Tabs(panelIds, activePanelId):
				if (hiddenPanels.length > 0) {
					panelIds = panelIds == null ? [] : [for (id in panelIds) if (hiddenPanels.indexOf(id) < 0) id];
					if (panelIds.length == 0) return new haxeon.ui.widgets.layout.Spacer(nodeKey, LayoutAxis.fixed(0), LayoutAxis.fixed(0));
					if (panelIds.indexOf(activePanelId) < 0) activePanelId = panelIds[0];
				}
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
			visiblePanels[0].headerMode == haxeon.ui.docking.DockPanelHeaderMode.Content)
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
		if (headerActions != null) options.headerTrailing = headerActions([for (panel in visiblePanels) panel.id], selectedId);
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
		return haxeon.ui.widgets.controls.Tabs.withOptions(nodeKey, items, activePanelId, function(next) {
			model.activate(next);
		}, options);
	}

	function matchesExpandedGroup(node:DockNode):Bool {
		var ids = haxeon.ui.docking.DockNodeTools.panelIds(node);
		if (ids.length == 0 || expandedGroup == null) return false;
		for (id in ids) if (expandedGroup.indexOf(id) < 0) return false;
		return true;
	}

	function tabLabelWidth(label:String, context:BuildContext,
		labelWidths:DockTextWidthCache):Float {
		if (context.fonts == null) return label.length * 8.0;
		var style = context.resolveTextRole(TextRole.Button,
			new TextStyleOverride(null, context.theme.tokens.tabHeaderFontSize, null, TextWrap.None));
		return labelWidths.measure(context.fonts, label, style.textStyle, style.paragraphStyle);
	}

	function hasPresentedPanel(node:DockNode):Bool {
		for (id in haxeon.ui.docking.DockNodeTools.panelIds(node))
			if (hiddenPanels.indexOf(id) < 0) return true;
		return false;
	}

	function buildSplit(axis:DockSplitAxis, ratio:Float, first:DockNode, second:DockNode,
		context:BuildContext, path:Array<Int>, nodeKey:String,
		availableWidth:Float, availableHeight:Float, labelWidths:DockTextWidthCache,
		panelCache:DockPanelCache, paneCache:DockPanelCache):View {
		var firstPath = path.copy();
		firstPath.push(0);
		var secondPath = path.copy();
		secondPath.push(1);
		if (hiddenPanels.length > 0) {
			if (!hasPresentedPanel(first)) return buildNode(second, context, secondPath, nodeKey + ":second",
				availableWidth, availableHeight, labelWidths, panelCache, paneCache);
			if (!hasPresentedPanel(second)) return buildNode(first, context, firstPath, nodeKey + ":first",
				availableWidth, availableHeight, labelWidths, panelCache, paneCache);
		}
		if (axis == DockSplitAxis.Vertical && expandedGroup != null) {
			if (matchesExpandedGroup(second) && !matchesExpandedGroup(first)) return buildNode(second, context, secondPath, nodeKey + ":second",
				availableWidth, availableHeight, labelWidths, panelCache, paneCache);
			if (matchesExpandedGroup(first) && !matchesExpandedGroup(second)) return buildNode(first, context, firstPath, nodeKey + ":first",
				availableWidth, availableHeight, labelWidths, panelCache, paneCache);
		}
		var horizontal = axis == DockSplitAxis.Horizontal;
		var available = horizontal ? availableWidth : availableHeight;
		if (available <= 0.0)
			available = 1000.0;
		var minimum = horizontal ? MinimumHorizontalExtent : 120.0;
		var divider = DividerExtent;
		var maximum = available - minimum;
		if (maximum < minimum)
			maximum = minimum;
		var options = new SplitViewOptions();
		options.orientation = horizontal ? SplitOrientation.Horizontal : SplitOrientation.Vertical;
		options.resizableSide = SplitSide.Leading;
		options.extent = clamp(ratio * available, minimum, maximum);
		options.minimumExtent = minimum;
		options.maximumExtent = maximum;
		options.dividerExtent = divider;
		options.dividerHairline = true;
		options.onResize = function(next) {
			model.setSplitRatio(path, next / available);
		};
		var remaining = Math.max(0.0, available - options.extent);
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
			availableWidth:Float, paneCache:DockPanelCache, create:Void->View):View {
		var retainable = fillPaneCacheKey(panelIds, activePanelId, context, nodeKey, availableWidth);
		return new DockPaneView(nodeKey, retainable, paneKeyHash.a, paneKeyHash.b, create, paneCache, interaction);
	}

	/**
	 * Fills `paneKeyHash` with everything the pane shows. False when the pane cannot be retained: its active panel has no
	 * cache key, so building it has effects the cache cannot see.
	 */
	function fillPaneCacheKey(panelIds:Array<String>, activePanelId:Null<String>, context:BuildContext, nodeKey:String,
			availableWidth:Float):Bool {
		if (panelIds == null || panelIds.length == 0)
			return false;
		var selected = activePanelId == null ? panelIds[0] : activePanelId;
		var content = panelContents.get(selected);
		var contentHasher:Null<DockPanelCacheKeyHasher> = content == null ? null : content.cacheKeyHash;
		var contentKey:Null<DockPanelCacheKeyBuilder> = content == null ? null : content.cacheKey;
		// An observed panel has no key of its own: the pane's cache records what the panel's build reads.
		if (contentHasher == null && contentKey == null && (content == null || !content.observed))
			return false;
		var hash = paneKeyHash.reset();
		hash.addString(nodeKey).addString(headerActionsRevision).addFloat(availableWidth).addInt(context.styleRevision)
			.addFloat(context.viewportWidth).addFloat(context.viewportHeight).addInt(interaction.revision).addString(selected);
		for (panelId in panelIds) {
			var descriptor = model.get(panelId);
			if (descriptor != null)
				hash.addString(panelId).addString(descriptor.title).addInt(descriptor.badgeCount)
					.addInt(descriptor.icon == null ? -1 : cast descriptor.icon).addBool(descriptor.enabled)
					.addInt(cast descriptor.headerMode);
		}
		if (contentHasher != null)
			contentHasher(hash);
		else if (contentKey != null)
			hash.addString(contentKey());
		return true;
	}

	function panelView(panelId:String, availableWidth:Float, panelCache:DockPanelCache):View {
		var descriptor = model.get(panelId);
		var content = panelContents.get(panelId);
		return descriptor == null ? new Text("Missing panel: " + panelId) : content == null ?
			new Text("Missing panel content: " + panelId) :
			new DockPanelView(descriptor, content, availableWidth, panelCache, panelScope);
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
	/** Single-threaded scratch: filled and read within one `build` before any child builds. */
	static final scratchKey:KeyHash = new KeyHash();
	final descriptor:DockPanelDescriptor;
	final content:DockPanelContent;
	final availableWidth:Float;
	final panelCache:DockPanelCache;
	final scope:KeyScope;

	public function new(descriptor:DockPanelDescriptor, content:DockPanelContent,
			availableWidth:Float, panelCache:DockPanelCache, scope:KeyScope) {
		this.descriptor = descriptor;
		this.content = content;
		this.availableWidth = availableWidth;
		this.panelCache = panelCache;
		this.scope = scope;
	}

	public function build(context:BuildContext):RenderNode {
		var cacheKeyBuilder:Null<DockPanelCacheKeyBuilder> = content.cacheKey;
		var cacheKeyHasher:Null<DockPanelCacheKeyHasher> = content.cacheKeyHash;
		var keyed = false;
		var keyA = 0, keyB = 0;
		if (cacheKeyHasher != null || cacheKeyBuilder != null || content.observed) {
			keyed = true;
			var hash = scratchKey.reset();
			if (cacheKeyHasher != null)
				cacheKeyHasher(hash);
			else if (cacheKeyBuilder != null)
				hash.addString(cacheKeyBuilder());
			hash.addInt(context.styleRevision).addFloat(context.viewportWidth).addFloat(context.viewportHeight)
				.addFloat(availableWidth);
			keyA = hash.a;
			keyB = hash.b;
		}
		var cached = keyed ? panelCache.entry(descriptor.id) : null;
		var hitStarted = context.buildProbe != null ? Sys.time() : 0.0;
		if (cached != null && !context.bypassRetention && cached.matches(keyA, keyB) && cached.statesMatch(context)) {
			context.retainStateIds(cached.stateIds);
			context.retainObserved(cached.observed);
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
		var intMark = context.observedIntMarker(), stringMark = context.observedStringMarker();
		var buildStarted = 0.0;
		// Keyed under the workspace, not the split path to the pane, so a panel keeps its state when the layout around it
		// changes: a neighbour closing, or the panel moving to another split.
		var root = context.withScopeUnder(scope, new Key("panel:" + descriptor.id), function() {
			var widthBuilder = content.buildWithWidth;
			var view = widthBuilder == null ? content.build(context) :
				widthBuilder(context, availableWidth);
			if (view == null)
				view = new Text("Panel returned no content: " + descriptor.id);
			buildStarted = observed ? Sys.time() : 0.0;
			return view.build(context);
		});
		if (observed)
			context.reportBuild("panel:" + descriptor.id, buildStarted - preparationStarted,
				Sys.time() - buildStarted, root);
		if (keyed) {
			var usedStates = context.stateIdsUsedSince(stateMarker);
			panelCache.put(descriptor.id, keyA, keyB, root, usedStates, context.stateRevisions(usedStates),
				new InteractionStateSnapshot(context.currentRoot(root), context), context.observedSince(intMark, stringMark));
		}
		return root;
	}
}

/** A retained pane: reuses the built tab strip and panel while its key and the interaction state inside it are unchanged. */
private class DockPaneView implements View {
	final key:String;
	final retainable:Bool;
	final keyA:Int;
	final keyB:Int;
	final create:Void->View;
	final cache:DockPanelCache;
	final interaction:DockWorkspaceInteraction;

	public function new(key:String, retainable:Bool, keyA:Int, keyB:Int, create:Void->View, cache:DockPanelCache,
			interaction:DockWorkspaceInteraction) {
		this.key = key;
		this.retainable = retainable;
		this.keyA = keyA;
		this.keyB = keyB;
		this.create = create;
		this.cache = cache;
		this.interaction = interaction;
	}

	public function build(context:BuildContext):RenderNode {
		var cached = retainable ? cache.entry(key) : null;
		if (cached != null && !context.bypassRetention && cached.matches(keyA, keyB) && cached.statesMatch(context)) {
			context.retainStateIds(cached.stateIds);
			context.retainObserved(cached.observed);
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
		var intMark = context.observedIntMarker(), stringMark = context.observedStringMarker();
		var targetMark = interaction.targetCount(), tabMark = interaction.tabTargetCount();
		var root = create().build(context);
		if (retainable) {
			var usedStates = context.stateIdsUsedSince(stateMarker);
			cache.put(key, keyA, keyB, root, usedStates, context.stateRevisions(usedStates),
				new InteractionStateSnapshot(context.currentRoot(root), context), context.observedSince(intMark, stringMark),
				interaction.targetsSince(targetMark),
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

	public function put(panelId:String, keyA:Int, keyB:Int, root:RenderNode, stateIds:Array<Int>,
			stateRevisions:Array<Int>, interactions:InteractionStateSnapshot, observed:haxeon.ui.core.Dependencies,
			?targets:Array<DockDropTarget>, ?tabTargets:Array<DockTabDropTarget>):Void {
		var previous = entries.get(panelId);
		if (previous != null && previous.root != root)
			previous.root.detach();
		entries.set(panelId, new DockPanelCacheEntry(keyA, keyB, root, stateIds, stateRevisions,
			interactions, observed, targets, tabTargets));
	}

	public function retain(context:BuildContext):Void {
		for (entry in entries)
			context.retainStateIds(entry.stateIds);
	}
}

private class DockPanelCacheEntry {
	final keyA:Int;
	final keyB:Int;
	public var root(default, null):RenderNode;
	public final stateIds:Array<Int>;
	/** Drop targets the build registered; a hit replays them because the interaction forgets them every frame. */
	public final targets:Array<DockDropTarget>;
	public final tabTargets:Array<DockTabDropTarget>;
	final stateRevisions:Array<Int>;
	final interactions:InteractionStateSnapshot;
	/** What the subtree's build read outside widget state (BuildContext.observeInt and friends). */
	public final observed:haxeon.ui.core.Dependencies;

	public function new(keyA:Int, keyB:Int, root:RenderNode, stateIds:Array<Int>, stateRevisions:Array<Int>,
			interactions:InteractionStateSnapshot, observed:haxeon.ui.core.Dependencies, ?targets:Array<DockDropTarget>,
			?tabTargets:Array<DockTabDropTarget>) {
		this.keyA = keyA;
		this.keyB = keyB;
		this.root = root;
		this.stateIds = stateIds == null ? [] : stateIds.copy();
		this.stateRevisions = stateRevisions == null ? [] : stateRevisions.copy();
		this.interactions = interactions;
		this.observed = observed;
		this.targets = targets == null ? [] : targets;
		this.tabTargets = tabTargets == null ? [] : tabTargets;
	}

	public function matches(otherA:Int, otherB:Int):Bool
		return keyA == otherA && keyB == otherB;

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
		return interactions.matches(context) && observed.current();
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
			"|direction=" + Std.string(paragraphStyle.direction) + "|tabs=" + paragraphStyle.tabWidth;
	}
}
