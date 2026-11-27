package haxeon.ui.widgets.navigation;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.Icon;

/** Bottom navigation: equal items with icon 22 and label 12; the active item is accent and the bar clears the safe area. */
class BottomBar implements ScopeView {
	/**
	 * The bottom safe-area inset new bars start with. The kit's build context cannot see the host, so the application
	 * sets this from `UiHostContext.safeBottom` before building (or sets `bottomInset` on one bar).
	 */
	public static var defaultBottomInset:Float = 0.0;

	/** Identifies the bar among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The destinations, in order. */
	public final items:Array<BottomBarItem>;

	/** The key of the current destination. */
	public final selected:String;

	/** Called with an item's key when the user chooses it. */
	public final onSelect:String->Void;

	/** The bar's box. */
	public final style:LayoutStyle;

	/** Space kept below the items for the device's safe area, in logical pixels. */
	public final bottomInset:Float;

	/** A bottom bar over `items` with `selected` current. Throws when `key` is empty. */
	public function new(key:String, items:Array<BottomBarItem>, selected:String, onSelect:String->Void,
			?style:LayoutStyle,
			bottomInset:Float = defaultBottomInset) {
		if (key == null || key.length == 0) throw "Bottom bars require a stable key";
		this.key = key;
		this.items = items == null ? [] : items.copy();
		this.selected = selected == null ? "" : selected;
		this.onSelect = onSelect;
		this.style = style == null ? new LayoutStyle() : style.copy();
		this.bottomInset = bottomInset;
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, BottomBar)) return false;
		var other:BottomBar = cast previous;
		if (key != other.key || selected != other.selected || onSelect != other.onSelect
			|| bottomInset != other.bottomInset || items.length != other.items.length
			|| haxeon.Diff.mask(style, other.style) != 0) return false;
		for (index in 0...items.length) {
			var a = items[index];
			var b = other.items[index];
			if (a.id != b.id || a.label != b.label || a.badge != b.badge || !haxeon.Equality.equals(a.icon, b.icon))
				return false;
		}
		return true;
	}

	public function buildBody(context:BuildContext):ViewRoot return buildBar(context, context.rootId("bottom-bar"));

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	function buildBar(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		var rootStyle = style.copy();
		rootStyle.direction = LayoutDirection.TopToBottom;
		rootStyle.width = LayoutAxis.grow();
		rootStyle.background = context.theme.tokens.surfaceRaised;
		var root = NavUi.box(context, id, "bottom-bar", key, rootStyle, ["bottom-bar"]);
		var tabs = new Semantics(AccessibilityRole.TabList, "Navigation");
		tabs.orientation = AccessibilityOrientation.Horizontal;
		root.semantics = tabs;

		var dividerStyle = new LayoutStyle();
		dividerStyle.width = LayoutAxis.grow();
		dividerStyle.height = LayoutAxis.fixed(1.0);
		dividerStyle.background = context.theme.tokens.border;
		root.add(NavUi.child(context, "divider", "bottom-bar-divider", dividerStyle));

		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.direction = LayoutDirection.LeftToRight;
		rowStyle.padding = new Insets(0.0, 6.0, 0.0, 6.0 + (bottomInset > 0.0 ? bottomInset : 0.0));
		var row = NavUi.child(context, "items", "bottom-bar-items", rowStyle);
		for (position in 0...items.length) {
			var item = items[position];
			row.add(context.withScope(new Key("item:" + item.id),
				function() return buildItem(context, item, position)));
		}
		root.add(row);
		return root;
	}

	function buildItem(context:BuildContext, item:BottomBarItem, position:Int):RenderNode {
		var active = item.id == selected;
		var itemStyle = new LayoutStyle();
		itemStyle.width = LayoutAxis.grow();
		itemStyle.height = LayoutAxis.fixed(56.0);
		itemStyle.direction = LayoutDirection.TopToBottom;
		itemStyle.childAlignX = LayoutAlignmentX.Center;
		itemStyle.childDistribution = LayoutDistribution.Center;
		itemStyle.childGap = 4.0;
		var node = NavUi.box(context, context.rootId("bottom-bar-item"), "bottom-bar-item", item.id, itemStyle,
			["bottom-bar-item"]);
		node.focusable = true;
		node.enabled = true;
		var semantics = new Semantics(AccessibilityRole.Tab, item.label);
		semantics.actions = AccessibilityAction.Activate;
		if (active) semantics.states |= AccessibilityState.Selected;
		semantics.setSize = items.length;
		semantics.positionInSet = position + 1;
		node.semantics = semantics;
		if (onSelect != null) {
			var chosen = item.id;
			node.onActivate(function(_:UiEvent) onSelect(chosen));
		}

		var foreground = active ? context.theme.tokens.accent : context.theme.tokens.textSecondary;
		node.add(context.withScope(new Key("icon"),
			function() return new Icon("glyph", item.icon, 22.0, foreground).build(context)));

		var labelRowStyle = new LayoutStyle();
		labelRowStyle.direction = LayoutDirection.LeftToRight;
		labelRowStyle.childAlignY = LayoutAlignmentY.Center;
		labelRowStyle.childGap = 4.0;
		var labelRow = NavUi.child(context, "caption", "bottom-bar-caption", labelRowStyle);
		labelRow.add(NavUi.label(context, "label", item.label, 12.0, foreground));
		if (item.badge != null && item.badge > 0) {
			var badgeStyle = new LayoutStyle();
			badgeStyle.height = LayoutAxis.fixed(16.0);
			badgeStyle.padding = new Insets(5.0, 0.0, 5.0, 0.0);
			badgeStyle.childAlignY = LayoutAlignmentY.Center;
			badgeStyle.childDistribution = LayoutDistribution.Center;
			badgeStyle.direction = LayoutDirection.LeftToRight;
			badgeStyle.background = context.theme.tokens.warning;
			badgeStyle.radiusTopLeft = 8.0;
			badgeStyle.radiusTopRight = 8.0;
			badgeStyle.radiusBottomLeft = 8.0;
			badgeStyle.radiusBottomRight = 8.0;
			var badge = NavUi.child(context, "badge", "bottom-bar-badge", badgeStyle);
			badge.add(NavUi.label(context, "count", Std.string(item.badge), 11.0, context.theme.tokens.textOnAccent));
			labelRow.add(badge);
		}
		node.add(labelRow);
		return node;
	}
}

/** One destination in a BottomBar; `badge` above zero shows a count. */
typedef BottomBarItem = {
	id:String,
	icon:IconName,
	label:String,
	?badge:Int
};
