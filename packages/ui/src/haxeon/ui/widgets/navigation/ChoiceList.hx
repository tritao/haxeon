package haxeon.ui.widgets.navigation;
import haxeon.ui.core.ViewRoot;

import haxeon.reactive.Signal;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.WidgetId;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.controls.SearchField;
import haxeon.ui.widgets.scroll.ScrollView;

/** A searchable list of choices for a sheet (single or multi select); items are indented by `depth`. */
class ChoiceList implements ScopeView {
	static inline var RowHeight:Float = 52.0;
	static inline var IndentPerDepth:Float = 16.0;

	/** Identifies the list among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The choices, in order. */
	public final items:Array<ChoiceItem>;

	/** The keys of the chosen items. */
	public final selected:Array<String>;

	/** Whether several items can be chosen. */
	public final multi:Bool;

	/** Called with the chosen keys after each change. */
	public final onChange:Array<String>->Void;

	/** The hint in the search field while it is empty. */
	public final searchPlaceholder:String;

	/** A searchable list of `items` with `selected` chosen. Throws when `key` is empty. */
	public function new(key:String, items:Array<ChoiceItem>, selected:Array<String>, multi:Bool,
			onChange:Array<String>->Void, ?searchPlaceholder:String) {
		if (key == null || key.length == 0) throw "Choice lists require a stable key";
		this.key = key;
		this.items = items == null ? [] : items.copy();
		this.selected = selected == null ? [] : selected.copy();
		this.multi = multi;
		this.onChange = onChange;
		this.searchPlaceholder = searchPlaceholder == null
			|| searchPlaceholder.length == 0 ? "Search" : searchPlaceholder;
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, ChoiceList)) return false;
		var other:ChoiceList = cast previous;
		if (key != other.key || multi != other.multi || onChange != other.onChange
			|| searchPlaceholder != other.searchPlaceholder || items.length != other.items.length
			|| selected.length != other.selected.length) return false;
		for (index in 0...items.length) {
			var a = items[index];
			var b = other.items[index];
			if (a.id != b.id || a.label != b.label || a.detail != b.detail || a.depth != b.depth) return false;
		}
		for (index in 0...selected.length) if (selected[index] != other.selected[index]) return false;
		return true;
	}

	public function buildBody(context:BuildContext):ViewRoot {
		var id = context.rootId("choice-list");
		return buildList(context, id);
	}

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	function isSelected(itemId:String):Bool return selected.indexOf(itemId) >= 0;

	function choose(itemId:String):Void {
		if (onChange == null) return;
		if (!multi) {
			onChange([itemId]);
			return;
		}
		var next = selected.copy();
		if (!next.remove(itemId)) next.push(itemId);
		onChange(next);
	}

	function buildList(context:BuildContext, id:WidgetId):RenderNode {
		var query = context.lazyState(context.id("query"), function() return new Signal<String>("")).value;
		var needle = query.value.toLowerCase();

		var rootStyle = new LayoutStyle();
		rootStyle.width = LayoutAxis.grow();
		rootStyle.direction = LayoutDirection.TopToBottom;
		var root = NavUi.box(context, id, "choice-list", key, rootStyle, ["choice-list"]);
		root.semantics = new Semantics(AccessibilityRole.Group, searchPlaceholder);

		var searchBox = new LayoutStyle();
		searchBox.width = LayoutAxis.grow();
		searchBox.padding = new Insets(16.0, 4.0, 16.0, 8.0);
		var searchWrap = NavUi.child(context, "search-wrap", "choice-list-search", searchBox);
		var fieldStyle = new LayoutStyle();
		fieldStyle.width = LayoutAxis.grow();
		fieldStyle.height = LayoutAxis.fixed(NavUi.touchTarget);
		fieldStyle.padding = new Insets(12.0, 0.0, 8.0, 0.0);
		fieldStyle.childGap = 8.0;
		fieldStyle.background = NavUi.chipFill;
		fieldStyle.radiusTopLeft = 10.0;
		fieldStyle.radiusTopRight = 10.0;
		fieldStyle.radiusBottomLeft = 10.0;
		fieldStyle.radiusBottomRight = 10.0;
		var search = new SearchField("search", query.value, function(next:String) {
			query.value = next;
		}, fieldStyle, searchPlaceholder);
		searchWrap.add(context.withScope(new Key("search-field"), function() return search.build(context)));
		root.add(searchWrap);

		var listStyle = new LayoutStyle();
		listStyle.width = LayoutAxis.grow();
		listStyle.direction = LayoutDirection.TopToBottom;
		var list = NavUi.child(context, "rows", "choice-list-rows", listStyle);
		list.semantics = new Semantics(AccessibilityRole.List, "Choices");
		var shown = 0;
		for (item in items) {
			var matches = needle.length == 0 || item.label.toLowerCase().indexOf(needle) >= 0
				|| (item.detail != null && item.detail.toLowerCase().indexOf(needle) >= 0);
			if (!matches) continue;
			shown++;
			list.add(context.withScope(new Key("item:" + item.id), function() return buildRow(context, item, shown)));
		}
		if (shown == 0) {
			var emptyStyle = new LayoutStyle();
			emptyStyle.width = LayoutAxis.grow();
			emptyStyle.padding = new Insets(16.0, 16.0, 16.0, 16.0);
			var empty = NavUi.child(context, "empty", "choice-list-empty", emptyStyle);
			empty.add(NavUi.label(context, "text", "No matches", 14.0, NavUi.secondary));
			list.add(empty);
		}
		var scrollStyle = new LayoutStyle();
		scrollStyle.width = LayoutAxis.grow();
		scrollStyle.height = LayoutAxis.fit(0.0, Math.max(160.0, context.viewportHeight * 0.55));
		root.add(new ScrollView("scroll", new RenderNodeView(list), scrollStyle, ScrollAxis.Vertical).build(context));
		return root;
	}

	function buildRow(context:BuildContext, item:ChoiceItem, position:Int):RenderNode {
		var chosen = isSelected(item.id);
		var depth = item.depth == null || item.depth < 0 ? 0 : item.depth;
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.height = LayoutAxis.fit(RowHeight, 0.0);
		rowStyle.direction = LayoutDirection.LeftToRight;
		rowStyle.childAlignY = LayoutAlignmentY.Center;
		rowStyle.childGap = 12.0;
		rowStyle.padding = new Insets(16.0 + IndentPerDepth * depth, 6.0, 16.0, 6.0);
		var row = NavUi.box(context, context.rootId("choice-row"), "choice-row", item.id, rowStyle, ["choice-row"]);
		row.focusable = true;
		row.enabled = true;
		var semantics = new Semantics(multi ? AccessibilityRole.Checkbox : AccessibilityRole.Button, item.label);
		semantics.actions = AccessibilityAction.Activate;
		if (chosen) semantics.states |= multi ? AccessibilityState.Checked : AccessibilityState.Selected;
		semantics.hierarchyLevel = depth + 1;
		row.semantics = semantics;
		var itemId = item.id;
		row.onActivate(function(_:UiEvent) choose(itemId));

		if (multi) row.add(buildCheckbox(context, chosen));

		var textStyle = new LayoutStyle();
		textStyle.width = LayoutAxis.grow();
		textStyle.direction = LayoutDirection.TopToBottom;
		textStyle.childGap = 2.0;
		var texts = NavUi.child(context, "texts", "choice-row-text", textStyle);
		texts.add(NavUi.label(context, "label", item.label, 16.0, chosen && !multi ? NavUi.accent : NavUi.text));
		if (item.detail != null && item.detail.length > 0)
			texts.add(NavUi.label(context, "detail", item.detail, 13.0, NavUi.secondary));
		row.add(texts);

		if (!multi && chosen)
			row.add(context.withScope(new Key("check"),
				function() return new Icon("check", IconName.Check, 18.0, NavUi.accent).build(context)));
		return row;
	}

	function buildCheckbox(context:BuildContext, checked:Bool):RenderNode {
		var boxStyle = new LayoutStyle();
		boxStyle.width = LayoutAxis.fixed(20.0);
		boxStyle.height = LayoutAxis.fixed(20.0);
		boxStyle.childAlignX = LayoutAlignmentX.Center;
		boxStyle.childAlignY = LayoutAlignmentY.Center;
		boxStyle.childDistribution = LayoutDistribution.Center;
		boxStyle.background = checked ? NavUi.accent : NavUi.rgb(0xd0d3da);
		boxStyle.padding = new Insets(checked ? 0.0 : 2.0, checked ? 0.0 : 2.0, checked ? 0.0 : 2.0,
			checked ? 0.0 : 2.0);
		boxStyle.radiusTopLeft = 5.0;
		boxStyle.radiusTopRight = 5.0;
		boxStyle.radiusBottomLeft = 5.0;
		boxStyle.radiusBottomRight = 5.0;
		var node = NavUi.child(context, "checkbox", "choice-checkbox", boxStyle);
		if (checked) node.add(new Icon("tick", IconName.Check, 14.0, NavUi.white).build(context));
		else {
			var innerStyle = new LayoutStyle();
			innerStyle.width = LayoutAxis.grow();
			innerStyle.height = LayoutAxis.grow();
			innerStyle.background = NavUi.surface;
			innerStyle.radiusTopLeft = 3.0;
			innerStyle.radiusTopRight = 3.0;
			innerStyle.radiusBottomLeft = 3.0;
			innerStyle.radiusBottomRight = 3.0;
			node.add(NavUi.child(context, "inner", "choice-checkbox-inner", innerStyle));
		}
		return node;
	}
}

/** Lets an already built node serve as the content view of a ScrollView. */
private class RenderNodeView implements haxeon.ui.core.View {
	final node:RenderNode;

	public function new(node:RenderNode) this.node = node;

	public function build(context:BuildContext):ViewRoot return node;
}

/** One option in a ChoiceList; `depth` indents nested options. */
typedef ChoiceItem = {
	id:String,
	label:String,
	?detail:String,
	?depth:Int
};
