package haxeon.ui.widgets.collections;
import haxeon.ui.LayoutSizing;

import haxeon.ui.widgets.KeyedView;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityOrientation;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Spacer;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;

/**
 * Model-backed variable-extent list that materializes only its viewport
 * window. Unmeasured rows use the model estimate until they enter that
 * window, so variable-height scroll positions can converge as rows are seen.
 */
class ListView implements View {
	public final key:String;
	public final model:ListViewModel;
	public final viewportStyle:LayoutStyle;
	public final virtualization:VirtualizationPolicy;
	public var controller(default, null):ScrollController;
	public var materializedFirst(default, null):Int;
	public var materializedLast(default, null):Int;
	/** Number of model extent measurements performed by this control. */
	public var extentMeasurements(default, null):Int;
	/** Number of cached extents reused after checking their item generation. */
	public var extentReuses(default, null):Int;
	public var selectedIndex(default, null):Int;
	public var onSelectionChanged:Null<Int->Void>;
	public var onItemActivated:Null<Int->Void>;
	/** Opt in for launcher lists whose primary click invokes the selected item. */
	public var activateOnClick:Bool = false;

	final fallbackViewportHeight:Float;
	var selectedState:Null<State<Int>>;
	var cachedRevision:Int;
	var cachedCount:Int;
	var cachedUniform:Bool;
	var extentCache:Map<String, Float>;
	var extentRevisionCache:Map<String, Int>;
	var extentIndex:Null<VirtualExtentIndex>;
	var itemIds:Map<Int, WidgetId>;
	var itemKeys:Map<Int, String>;
	final itemMetadata:Null<ListViewItemMetadata>;

	public function new(key:String, model:ListViewModel, ?viewportStyle:LayoutStyle,
			?controller:ScrollController, viewportHeight:Float = 300.0,
			selectedIndex:Int = -1, ?onSelectionChanged:Int->Void,
			?onItemActivated:Int->Void, ?virtualization:VirtualizationPolicy,
			?itemMetadata:ListViewItemMetadata) {
		if (key == null || key.length == 0 || model == null || viewportHeight <= 0.0 ||
			!finite(viewportHeight) || selectedIndex < -1)
			throw "ListView requires a stable key, model, and valid viewport height";
		this.key = key;
		this.model = model;
		this.itemMetadata = itemMetadata;
		this.viewportStyle = viewportStyle == null ? defaultViewportStyle(viewportHeight) :
			viewportStyle.copy();
		this.controller = controller == null ? new ScrollController() : controller;
		this.fallbackViewportHeight = viewportHeight;
		this.selectedIndex = selectedIndex;
		this.onSelectionChanged = onSelectionChanged;
		this.onItemActivated = onItemActivated;
		this.virtualization = virtualization == null ? new VirtualizationPolicy() : virtualization;
		materializedFirst = 0;
		materializedLast = 0;
		extentMeasurements = 0;
		extentReuses = 0;
		selectedState = null;
		cachedRevision = -1;
		cachedCount = -1;
		cachedUniform = false;
		extentCache = new Map();
		extentRevisionCache = new Map();
		extentIndex = null;
		itemIds = new Map();
		itemKeys = new Map();
	}

	/** Selects an item, or clears selection with -1. */
	public function select(index:Int):Bool {
		ensureModelMetrics();
		if (index < -1 || index >= cachedCount)
			throw "ListView selection index is out of range";
		if (index >= 0 && !itemEnabled(index))
			return false;
		if (index == selectedIndex)
			return false;
		selectedIndex = index;
		if (selectedState != null) {
			var state:State<Int> = cast selectedState;
			state.update(index);
		}
		if (onSelectionChanged != null)
			onSelectionChanged(index);
		return true;
	}

	/** Scrolls the requested item to the top of the viewport. */
	public function scrollTo(index:Int):Bool {
		ensureModelMetrics();
		if (index < 0 || index >= cachedCount)
			throw "ListView scroll index is out of range";
		var target = extentIndex == null ? 0.0 : extentOffset(index);
		return controller.jumpTo(controller.offsetX, target);
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			ensureModelMetrics();
			var state:State<Int> = context.state(context.id("selected-index"), selectedIndex);
			selectedState = state;
			if (state.value < -1 || state.value >= cachedCount)
				state.update(-1);
			if (state.value >= 0 && !itemEnabled(state.value))
				state.update(-1);
			selectedIndex = state.value;
			itemIds = new Map();
			itemKeys = new Map();

			var viewportHeight = controller.viewportHeight > 0.0 ? controller.viewportHeight :
				(viewportStyle.height.sizing == LayoutSizing.Fixed ? viewportStyle.height.value :
				fallbackViewportHeight);
			var window = requiredExtentIndex();
			measureWindowPreservingAnchor(window, viewportHeight);
			materializedFirst = window.first;
			materializedLast = window.last;

			var rowViews:Array<KeyedView> = [];
			if (window.count > 0) {
				var seenItemKeys:Map<String, Bool> = new Map();
				rowViews.push(new KeyedView("before", new Spacer("before-spacer",
					LayoutAxis.grow(), LayoutAxis.fixed(window.startOffset(window.first)))));
				for (index in window.first...window.last) {
					var itemIndex = index;
					var itemKey = itemKeyAt(itemIndex);
					if (seenItemKeys.exists(itemKey))
						throw 'ListView contains duplicate item key $itemKey';
					seenItemKeys.set(itemKey, true);
					var item = model.buildItem(itemIndex);
					if (item == null)
						throw 'ListView model returned null for index $itemIndex';
					var row = new ListViewRow("row", itemKey, item, cachedCount, itemIndex,
						window.extentAt(itemIndex), selectedIndex == itemIndex,
						itemMetadata == null ? null : itemMetadata.labelAt(itemIndex),
						itemEnabled(itemIndex), activateOnClick,
						function() { select(itemIndex); },
						function() { if (onItemActivated != null) onItemActivated(itemIndex); },
						function(event) { handleItemKey(context, itemIndex, event); },
						function(id) { itemIds.set(itemIndex, id); });
					var slotKey = virtualization.recycleSlots ? 'slot:${index - window.first}' :
						'item:$itemKey';
					rowViews.push(new KeyedView(slotKey, row));
				}
				rowViews.push(new KeyedView("after", new Spacer("after-spacer",
					LayoutAxis.grow(), LayoutAxis.fixed(Math.max(0.0, window.totalExtent -
					window.startOffset(window.last))))));
			}

			var contentStyle = new LayoutStyle();
			contentStyle.width = LayoutAxis.grow();
			contentStyle.height = LayoutAxis.fixed(window.totalExtent);
			var content = new Column("list-content", rowViews, contentStyle);
			var scroll = new ScrollView("viewport", content, viewportStyle,
				ScrollAxis.Vertical, controller);
			var root = new RenderNode(context.id("list"), LayoutVisualKind.Box);
			root.layout.style.width = viewportStyle.width;
			root.layout.style.height = viewportStyle.height;
			var semantics = new Semantics(AccessibilityRole.Collection);
			semantics.setSize = cachedCount;
			semantics.orientation = AccessibilityOrientation.Vertical;
			semantics.actions = AccessibilityAction.ScrollForward | AccessibilityAction.ScrollBackward;
			root.semantics = semantics;
			var viewport = context.withScope(new Key("scroll-view"), function() return scroll.build(context));
			root.add(viewport);
			return root;
		});
	}

	function handleItemKey(context:BuildContext, index:Int, event:UiEvent):Void {
		var next = index;
		switch (event.key) {
			case UiKey.Up: next--;
			case UiKey.Down: next++;
			case UiKey.Home: next = 0;
			case UiKey.End: next = cachedCount - 1;
			case UiKey.PageUp: next -= visibleItemCount();
			case UiKey.PageDown: next += visibleItemCount();
			default: return;
		}
		if (cachedCount == 0)
			return;
		next = Std.int(Math.max(0, Math.min(cachedCount - 1, next)));
		var step = event.key == UiKey.Up || event.key == UiKey.End ||
			event.key == UiKey.PageUp ? -1 : 1;
		while (next >= 0 && next < cachedCount && !itemEnabled(next))
			next += step;
		if (next < 0 || next >= cachedCount)
			return;
		if (next == index)
			return;
		event.preventDefault();
		select(next);
		scrollTo(next);
		var target = itemIds.get(next);
		if (target != null)
			context.requestFocus(target);
	}

	function itemEnabled(index:Int):Bool
		return itemMetadata == null || itemMetadata.enabledAt(index);

	function visibleItemCount():Int {
		if (extentIndex == null)
			return 1;
		var viewport = requiredExtentIndex();
		if (viewport.count == 0)
			return 1;
		return Std.int(Math.max(1.0, Math.ceil(viewport.viewportExtent /
			Math.max(1.0, viewport.extentAt(viewport.first)))));
	}

	function ensureModelMetrics():Void {
		var count = model.count();
		if (count < 0)
			throw "ListView model count must be non-negative";
		var revision = model.revision();
		if (cachedRevision == revision && cachedCount == count && extentIndex != null)
			return;
		var estimatedExtent = model.estimatedExtent();
		if (estimatedExtent <= 0.0 || !finite(estimatedExtent))
			throw "ListView estimated extent must be finite and positive";
		cachedUniform = model.extentIsUniform();
		cachedRevision = revision;
		cachedCount = count;
		extentIndex = new VirtualExtentIndex(count, estimatedExtent,
			fallbackViewportHeight, controller.offsetY,
			virtualization.leadingOverscan, virtualization.trailingOverscan,
			validatedTotalExtent());
		if (selectedIndex >= cachedCount)
			selectedIndex = -1;
	}

	function validatedTotalExtent():Null<Float> {
		var total = model.totalExtent();
		if (total == null)
			return null;
		if (total < 0.0 || !finite(total))
			throw "ListView total extent must be finite and non-negative";
		return total;
	}

	function measureWindow(first:Int, last:Int):Void {
		if (extentIndex == null || cachedUniform)
			return;
		for (index in first...last) {
			var itemKey = itemKeyAt(index);
			var extentRevision = model.extentRevisionAt(index);
			var cachedRevisionForKey = extentRevisionCache.get(itemKey);
			var cachedExtent = extentCache.get(itemKey);
			var extent:Float;
			if (cachedExtent != null && cachedRevisionForKey != null &&
				cachedRevisionForKey == extentRevision) {
				extent = cachedExtent;
				extentReuses++;
			} else {
				extent = model.extentAt(index);
				extentMeasurements++;
			}
			if (extent <= 0.0 || !finite(extent))
				throw 'ListView extent for index $index must be finite and positive';
			extentCache.set(itemKey, extent);
			extentRevisionCache.set(itemKey, extentRevision);
			var indexMetrics = requiredExtentIndex();
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

	function itemKeyAt(index:Int):String {
		var cached = itemKeys.get(index);
		if (cached != null)
			return cached;
		var itemKey = model.keyAt(index);
		if (itemKey == null || itemKey.length == 0)
			throw 'ListView item $index has an empty key';
		itemKeys.set(index, itemKey);
		return itemKey;
	}

	function extentOffset(index:Int):Float {
		if (extentIndex == null)
			return 0.0;
		var viewport = requiredExtentIndex();
		return viewport.startOffset(index);
	}

	function requiredExtentIndex():VirtualExtentIndex {
		var result = extentIndex;
		if (result == null)
			throw "ListView extent metrics are not initialized";
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

private class ListViewRow implements View {
	final key:String;
	final itemKey:String;
	final child:View;
	final setSize:Int;
	final index:Int;
	final extent:Float;
	final selected:Bool;
	final label:Null<String>;
	final enabled:Bool;
	final activateOnClick:Bool;
	final onSelect:Void->Void;
	final onActivate:Void->Void;
	final onKey:UiEvent->Void;
	final onBuilt:WidgetId->Void;

	public function new(key:String, itemKey:String, child:View, setSize:Int, index:Int, extent:Float,
			selected:Bool, label:Null<String>, enabled:Bool, activateOnClick:Bool,
			onSelect:Void->Void, onActivate:Void->Void,
			onKey:UiEvent->Void, onBuilt:WidgetId->Void) {
		this.key = key;
		this.itemKey = itemKey;
		this.child = child;
		this.setSize = setSize;
		this.index = index;
		this.extent = extent;
		this.selected = selected;
		this.label = label;
		this.enabled = enabled;
		this.activateOnClick = activateOnClick;
		this.onSelect = onSelect;
		this.onActivate = onActivate;
		this.onKey = onKey;
		this.onBuilt = onBuilt;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			style.height = LayoutAxis.fixed(extent);
			style.background = selected ? context.theme.tokens.selectionHighlight :
				Color.rgba(0.0, 0.0, 0.0, 0.0);
			var node = new RenderNode(context.id("list-item"), LayoutVisualKind.Box, style);
			node.focusable = enabled;
			node.enabled = enabled;
			var semantics = new Semantics(AccessibilityRole.CollectionItem, label);
			if (enabled) {
				semantics.actions = AccessibilityAction.Activate | AccessibilityAction.Select;
				semantics.states |= AccessibilityState.Focusable;
			} else
				semantics.states |= AccessibilityState.Disabled;
			if (selected)
				semantics.states |= AccessibilityState.Selected;
			semantics.setSize = setSize;
			semantics.positionInSet = index + 1;
			node.semantics = semantics;
			if (enabled) {
				node.on(UiEventKind.Click, function(event) {
					onSelect();
					if (activateOnClick && event.button == 0) onActivate();
				});
				node.on(UiEventKind.Activate, function(_) { onSelect(); onActivate(); });
				node.on(UiEventKind.KeyDown, onKey);
				node.on(UiEventKind.KeyRepeat, onKey);
			}
			node.add(new KeyedView('item:$itemKey', child).build(context));
			onBuilt(node.id);
			return node;
		});
	}
}
