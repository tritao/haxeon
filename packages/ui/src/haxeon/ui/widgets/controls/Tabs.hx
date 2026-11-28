package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.reactive.Signal;
import haxeon.ui.Insets;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.icons.IconName;

/**
 * Scrollable tab strip over the selected tab's page. A local strip keeps the user's selection itself; a controlled one
 * shows the caller's `selectedKey` and only reports the user's choice through `onChange`.
 */
class Tabs implements ScopeView {
	/** Identifies the strip among its siblings, so its selection survives rebuilds: required, and never empty. */
	public final key:String;
	/** The tabs, in header order. */
	public final items:Array<TabItem>;

	/**
	 * The key of the selected tab; an empty or unknown key selects the first enabled tab. A local strip starts from it
	 * and then shows the user's choice here.
	 */
	public var selectedKey(default, null):String;
	/** Whether selection is kept by the strip or supplied by the caller. */
	public final selectionMode:TabsSelectionMode;
	/** The box holding the header strip and the selected page. */
	public final style:LayoutStyle;

	/** Called with the key of the tab the user selects. */
	public final onChange:Null<String->Void>;
	/** Called with a tab's key when the user starts dragging it, for dock hosts. */
	public final onTabDragStart:Null<String->UiEvent->Void>;
	/** Called with the dragged tab's key as the pointer moves during a tab drag. */
	public final onTabDragMove:Null<String->UiEvent->Void>;
	/** Called with the dragged tab's key when the pointer is released. */
	public final onTabDragEnd:Null<String->UiEvent->Void>;
	/** Called with the dragged tab's key when a tab drag is abandoned, as by Escape or a lost pointer capture. */
	public final onTabDragCancel:Null<String->UiEvent->Void>;
	/** Requests a menu for an enabled tab without changing the selected page. */
	public final onTabContextMenu:Null<String->UiEvent->Void>;
	/**
	 * Called while the strip builds with each tab's header, the strip's own node around its button, so dock hosts can
	 * register geometry or add to it. It shapes what the strip builds, so a new function always builds the strip again.
	 */
	public final onTabHeaderBuilt:Null<String->RenderNode->Void>;
	/** Fixed actions beside the scrolling tab strip. */
	public final headerTrailing:Null<View>;

	/**
	 * A tab strip over `items` with `selectedKey` selected. The drag callbacks and `selectionMode` are for dock hosts;
	 * callers give these and the later inputs by name (`new Tabs("tabs", items, tab, select, selectionMode: Controlled)`).
	 * Throws when `key` is empty or two tabs share a key.
	 */
	public function new(key:String,
			items:Array<TabItem>,
			selectedKey:String = "",
			?onChange:String->Void,
			?style:LayoutStyle,
			?onTabDragStart:String->UiEvent->Void,
			?onTabDragMove:String->UiEvent->Void,
			?onTabDragEnd:String->UiEvent->Void,
			?onTabDragCancel:String->UiEvent->Void,
			?selectionMode:TabsSelectionMode,
			?onTabHeaderBuilt:String->RenderNode->Void,
			?onTabContextMenu:String->UiEvent->Void,
			?headerTrailing:View) {
		if (key == null || key.length == 0) throw "Tabs require a stable key";
		this.key = key;
		this.items = items == null ? [] : items.copy();
		this.selectedKey = selectedKey == null ? "" : selectedKey;
		this.selectionMode = selectionMode == null ? TabsSelectionMode.Local : selectionMode;
		this.style = style == null ? defaultStyle() : style.copy();
		this.onChange = onChange;
		this.onTabDragStart = onTabDragStart;
		this.onTabDragMove = onTabDragMove;
		this.onTabDragEnd = onTabDragEnd;
		this.onTabDragCancel = onTabDragCancel;
		this.onTabHeaderBuilt = onTabHeaderBuilt;
		this.onTabContextMenu = onTabContextMenu;
		this.headerTrailing = headerTrailing;
		var keys:Map<String, Bool> = new Map();
		for (item in this.items) {
			if (item == null || keys.exists(item.key)) throw "Tab keys must be unique";
			keys.set(item.key, true);
		}
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, Tabs)) return false;
		var other:Tabs = cast previous;
		if (key != other.key || selectionMode != other.selectionMode || items.length != other.items.length
			|| haxeon.Diff.mask(style, other.style) != 0 || headerTrailing != other.headerTrailing
			|| onTabHeaderBuilt != other.onTabHeaderBuilt || (onChange == null) != (other.onChange == null)
			|| (onTabContextMenu == null) != (other.onTabContextMenu == null) || dragged() != other.dragged())
			return false;
		// A local strip's own selection outlives the key it started from.
		if (selectionMode == TabsSelectionMode.Controlled && selectedKey != other.selectedKey) return false;
		for (index in 0...items.length) if (!items[index].sameAs(other.items[index])) return false;
		return true;
	}

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	public function buildBody(context:BuildContext):ViewRoot {
		var rootId = context.rootId("tabs");
		var selection = context.lazyState(context.id("selected-tab"), () -> new Signal<String>(selectedKey))
			.value;
		var active = selectionMode == TabsSelectionMode.Controlled ? selectedKey : selection.value;
		if (!isEnabled(active)) active = firstEnabled();
		selectedKey = active;
		var latest = context.latestOf(this);
		var select = (next:String) -> {
			var tabs = latest();
			if (next == tabs.selectedKey) return;
			if (tabs.selectionMode == TabsSelectionMode.Local) {
				tabs.selectedKey = next;
				selection.value = next;
			}
			var handler = tabs.onChange;
			if (handler != null) handler(next);
		};

		var rootIdentity = new StyleIdentity("tabs", key, key, null, ["tabs"]);
		var rootComputed = context.resolveStyled(rootId, rootIdentity, style);
		var root = context.createNode(rootId, LayoutVisualKind.Box, rootComputed.toLayoutStyle());
		context.applyStyled(root, rootIdentity, rootComputed);
		var tabsSemantics = new Semantics(AccessibilityRole.TabList, "Tabs");
		tabsSemantics.orientation = AccessibilityOrientation.Horizontal;
		root.semantics = tabsSemantics;
		var trailing = headerTrailing;
		var strip = scrollStrip(buildStrip(context, rootComputed, active, select, latest), context, active,
			trailing == null ? LayoutAxis.stretch() : LayoutAxis.grow());
		if (trailing != null) {
			var headerStyle = new LayoutStyle();
			headerStyle.width = LayoutAxis.grow();
			headerStyle.height = LayoutAxis.fixed(context.theme.tokens.tabHeaderHeight);
			headerStyle.direction = LayoutDirection.LeftToRight;
			headerStyle.childAlignY = haxeon.ui.LayoutStyle.LayoutAlignmentY.Center;
			var header = context.createNode(context.rootId("header-with-actions"), LayoutVisualKind.Box, headerStyle);
			header.hitTestSelf = false;
			header.add(strip);
			header.add(context.withScope(new Key("header-actions"), () -> context.build(trailing)));
			root.add(header);
		} else root.add(strip);

		var selectedItem:Null<TabItem> = null;
		for (item in items) if (item.key == active) {
			selectedItem = item;
			break;
		}
		if (selectedItem != null) {
			var item:TabItem = cast selectedItem;
			var panel = context.withScope(new Key("panel:" + item.key), () -> {
				var panelStyle = new LayoutStyle();
				panelStyle.width = LayoutAxis.stretch();
				panelStyle.height = LayoutAxis.grow();
				panelStyle.direction = LayoutDirection.TopToBottom;
				var node = context.createNode(context.rootId("tab-panel"), LayoutVisualKind.Box, panelStyle);
				node.semantics = new Semantics(AccessibilityRole.TabPanel, item.label);
				var contentModifier = new RootModifier();
				contentModifier.width = LayoutAxis.stretch();
				var content = context.withStyleParent(rootComputed, () -> {
					return context.withScope(new Key("content"), () -> context.build(item.content,
						contentModifier));
				});
				// A quiet content boundary is independent of the active-tab accent.
				var dividerStyle = new LayoutStyle();
				dividerStyle.width = LayoutAxis.stretch();
				dividerStyle.height = LayoutAxis.fixed(1.0);
				dividerStyle.background = context.theme.tokens.border;
				var divider = context.createNode(context.rootId("tab-content-divider"), LayoutVisualKind.Box,
					dividerStyle);
				divider.hitTestSelf = false;
				node.add(divider);
				node.add(content);
				return node;
			});
			root.add(panel);
		}
		return root;
	}

	function buildStrip(context:BuildContext,
			rootComputed:ComputedStyle,
			active:String,
			select:String->Void,
			latest:Void->Tabs):RenderNode {
		var stripStyle = new LayoutStyle();
		stripStyle.width = LayoutAxis.fit();
		stripStyle.height = LayoutAxis.fixed(context.theme.tokens.tabHeaderHeight);
		stripStyle.direction = LayoutDirection.LeftToRight;
		stripStyle.childGap = 4.0;
		var strip = context.createNode(context.rootId("tab-strip"), LayoutVisualKind.Box, stripStyle);
		var buttonNodes:Array<ViewRoot> = [];
		var drag = dragged() ? context.lazyState(context.id("tab-drag"),
			() -> new TabDragState()).value : null;
		for (item in items) {
			var tabKey = item.key;
			var buttonStyle = new LayoutStyle();
			buttonStyle.height = LayoutAxis.fixed(context.theme.tokens.tabHeaderHeight);
			var tabName = item.label + (item.badgeCount > 0 ? ", " + item.badgeCount : "");
			var tabSemantics = new Semantics(AccessibilityRole.Tab, tabName);
			tabSemantics.actions = AccessibilityAction.Select;
			var button = new Button(item.displayLabel == null ? item.label : item.displayLabel, buttonStyle, null,
				tabKey,
				item.enabled, ButtonVariant.Navigation, tabKey == active, ["tab-header"], item.icon, null,
				item.iconView,
				item.badgeCount > 0 ? new CountBadge(item.badgeCount) : null, null, null, 14.0, tabName,
				event -> {
					if (event.kind == UiEventKind.Activate || event.button == 0) select(tabKey);
				}, tabSemantics);
			// What the strip adds to each tab button goes through its modifier: the button owns its root.
			var tabIndex = buttonNodes.length;
			var buttonModifier = new RootModifier();
			var closeFocus:Null<Signal<Bool>> = null;
			if (item.onClose != null) {
				var focus = context.lazyState(context.id("tab-close-focus:" + tabKey),
					() -> new Signal(false))
					.value;
				trackFocus(buttonModifier, focus);
				closeFocus = focus;
			}
			if (drag != null) installTabDragHandlers(buttonModifier, tabKey, drag, latest);
			if (item.enabled && onTabContextMenu != null) {
				var requestMenu = (event:UiEvent) -> {
					var handler = latest().onTabContextMenu;
					if (handler == null) return;
					handler(tabKey, event);
					event.preventDefault();
					event.stopPropagation();
				};
				buttonModifier.on(UiEventKind.PointerDown, event -> {
					if (event.button == 1) requestMenu(event);
				});
				buttonModifier.on(UiEventKind.KeyDown, event -> {
					if (event.isContextMenuRequest()) requestMenu(event);
				});
			}
			buttonModifier.on(UiEventKind.KeyDown, event -> {
				var direction = event.key == UiKey.Right
					|| event.key == UiKey.Down ? 1 : event.key == UiKey.Left || event.key == UiKey.Up ? -1 : 0;
				if (direction == 0 || buttonNodes.length == 0) return;
				var nextIndex = tabIndex;
				for (_ in 0...buttonNodes.length) {
					nextIndex = (nextIndex + direction + buttonNodes.length) % buttonNodes.length;
					if (items[nextIndex].enabled) break;
				}
				if (items[nextIndex].enabled) {
					select(items[nextIndex].key);
					context.requestFocus(buttonNodes[nextIndex].id);
					event.preventDefault();
				}
			});
			var buttonNode = context.withStyleParent(rootComputed, () -> {
				return context.withScope(new Key(tabKey), () -> context.build(button, buttonModifier));
			});
			var headerStyle = new LayoutStyle();
			headerStyle.direction = LayoutDirection.TopToBottom;
			headerStyle.height = LayoutAxis.fixed(context.theme.tokens.tabHeaderHeight);
			var header = context.createNode(context.rootId("tab-header:" + tabKey), LayoutVisualKind.Box, headerStyle);
			header.hitTestSelf = false;
			if (item.enabled && item.onClose != null) header.on(UiEventKind.Click, event -> {
				if (event.button != 2) return;
				event.preventDefault();
				event.stopPropagation();
				closeTab(latest(), tabKey);
			}, UiEventPhase.Capture);
			var headerContent = closeFocus == null ? buttonNode : buildClosableHeader(context, item, buttonNode,
				closeFocus, latest);
			header.add(headerContent);
			// Inactive accents are fully transparent and have no layout or hit-test effect.
			if (tabKey == active) {
				var indicatorStyle = new LayoutStyle();
				indicatorStyle.width = LayoutAxis.grow();
				indicatorStyle.height = LayoutAxis.fixed(2.0);
				indicatorStyle.positioning = haxeon.ui.LayoutStyle.LayoutPositioning.Absolute;
				indicatorStyle.zIndex = 1;
				indicatorStyle.clipToParent = true;
				indicatorStyle.background = context.theme.tokens.accent;
				var indicator = context.createNode(context.rootId("tab-indicator:" + tabKey),
					LayoutVisualKind.Box,
					indicatorStyle);
				indicator.hitTestSelf = false;
				header.add(indicator);
			}
			strip.add(header);
			buttonNodes.push(buttonNode);
			// The header is the strip's own node around the button: hosts may add to it.
			if (onTabHeaderBuilt != null) onTabHeaderBuilt(tabKey, header);
		}
		return strip;
	}

	/** Keep intrinsic header widths; overflow belongs to a clipped viewport, not the labels. */
	function scrollStrip(strip:RenderNode, context:BuildContext, active:String, width:LayoutAxis):ViewRoot {
		var state = context.lazyState(context.id("tab-scroll-state"), () -> new TabsScrollState()).value;
		var style = new LayoutStyle();
		style.width = width;
		style.height = LayoutAxis.fixed(context.theme.tokens.tabHeaderHeight);
		var scroll = new ScrollView("tab-viewport",
			new TabsStripView(strip),
			style,
			ScrollAxis.Horizontal,
			state.controller,
			onScroll: event -> {
				if (event.deltaX == 0 && state.controller.scrollBy(event.deltaY, 0)) {
					event.preventDefault();
					event.stopPropagation();
				}
			},
				showScrollbar: false);
		var viewport = scroll.build(context);
		for (index in 0...items.length) if (items[index].key == active) {
			var header = strip.children[index];
			// Layout scrolls the active tab into view as it settles the strip's offset: when it is newly active here, or
			// after the strip was resized (seen after a layout, so it applies on the next one).
			if (state.selected != active) {
				state.selected = active;
				state.controller.revealNode(false, header.layout.id);
			}
			header.onResolved(_ -> {
				var bounds = viewport.resolved;
				if (bounds == null || state.width == bounds.width) return;
				var resized = state.width >= 0;
				state.width = bounds.width;
				if (!resized) return;
				state.controller.revealNode(false, header.layout.id);
				context.requestLayout();
			});
		}
		return viewport;
	}

	function buildClosableHeader(context:BuildContext, item:TabItem, buttonNode:ViewRoot, focused:Signal<Bool>,
			latest:Void->Tabs):RenderNode {
		var tabKey = item.key;
		var rowStyle = new LayoutStyle();
		rowStyle.direction = LayoutDirection.LeftToRight;
		rowStyle.childAlignY = LayoutAlignmentY.Center;
		rowStyle.background = buttonNode.background;
		var row = context.createNode(context.rootId("tab-actions:" + tabKey), LayoutVisualKind.Box, rowStyle);
		row.hitTestSelf = false;
		row.add(buttonNode);
		var hover = context.lazyState(context.id("tab-close-hover:" + tabKey),
			() -> new Signal(false)).value;
		var slotStyle = new LayoutStyle();
		slotStyle.width = LayoutAxis.fixed(28);
		slotStyle.height = LayoutAxis.fixed(24);
		var slot = context.createNode(context.rootId("tab-close-slot:" + tabKey), LayoutVisualKind.Box, slotStyle);
		slot.hitTestSelf = true;
		var closeStyle = new LayoutStyle();
		closeStyle.width = LayoutAxis.fixed(24);
		closeStyle.height = LayoutAxis.fixed(24);
		closeStyle.padding = new Insets(4, 4, 4, 4);
		var close = new Button("",
			closeStyle, null, "tab-close:" + tabKey, item.enabled, ButtonVariant.Navigation, null, ["tab-close"],
			haxeon.ui.icons.IconName.Close, null, null, null, null, null, 14, "Close " + item.label, event -> {
				event.stopPropagation();
				if (event.kind == UiEventKind.Activate || event.button == 0) closeTab(latest(), tabKey);
			});
		var closeModifier = new RootModifier();
		closeModifier.on(UiEventKind.PointerDown, event -> event.stopPropagation());
		closeModifier.on(UiEventKind.PointerUp, event -> event.stopPropagation());
		// Built from the hover and focus signals, which the handlers only set: the rerun they cause shows or hides it.
		closeModifier.visible = hover.value || focused.value;
		trackFocus(closeModifier, focused);
		var closeNode = context.build(close, closeModifier);
		row.onTargetBubble(UiEventKind.HoverEnter, event -> {
			if (event.target.equals(row.id)) hover.value = true;
		});
		row.onTargetBubble(UiEventKind.HoverLeave, event -> {
			if (event.target.equals(row.id)) hover.value = false;
		});
		slot.add(closeNode);
		row.add(slot);
		return row;
	}

	static function trackFocus(modifier:RootModifier, focused:Signal<Bool>):Void {
		modifier.on(UiEventKind.Focus, _ -> focused.value = true, UiEventPhase.Capture);
		modifier.on(UiEventKind.Blur, _ -> focused.value = false, UiEventPhase.Capture);
	}

	/** Calls the close action of the tab `tabKey` in the latest description, if it still has one. */
	static function closeTab(tabs:Tabs, tabKey:String):Void {
		for (item in tabs.items) if (item.key == tabKey) {
			var close = item.onClose;
			if (close != null) close();
			return;
		}
	}

	function dragged():Bool {
		return onTabDragStart != null || onTabDragMove != null || onTabDragEnd != null || onTabDragCancel != null;
	}

	function isEnabled(key:String):Bool {
		for (item in items) if (item.enabled && item.key == key) return true;
		return false;
	}

	function firstEnabled():String {
		for (item in items) if (item.enabled) return item.key;
		return "";
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.direction = LayoutDirection.TopToBottom;
		result.childGap = 0.0;
		return result;
	}

	/** The drag is the strip's own bookkeeping, read only by these handlers, so changing it reruns nothing. */
	static function installTabDragHandlers(modifier:RootModifier, tabKey:String, drag:TabDragState,
			latest:Void->Tabs):Void {
		modifier.on(UiEventKind.PointerDown, event -> {
			if (event.button != 0) return;
			drag.active = true;
			drag.dragging = false;
			drag.pointerId = event.pointerId;
			drag.tabKey = tabKey;
			drag.startX = event.x;
			drag.startY = event.y;
			// Dock targets stay inside the workspace. Logical capture keeps the
			// drag routed to this tab without grabbing the native window pointer.
			event.capturePointer(false);
		});
		modifier.on(UiEventKind.PointerMove, event -> {
			if (!drag.active || drag.pointerId != event.pointerId || drag.tabKey != tabKey) return;
			var tabs = latest();
			var dx = event.x - drag.startX;
			var dy = event.y - drag.startY;
			if (!drag.dragging && dx * dx + dy * dy >= 36.0) {
				drag.dragging = true;
				var start = tabs.onTabDragStart;
				if (start != null) start(tabKey, event);
			}
			if (drag.dragging) {
				var move = tabs.onTabDragMove;
				if (move != null) move(tabKey, event);
				event.preventDefault();
			}
		});
		modifier.on(UiEventKind.PointerUp, event -> {
			if (!drag.active || drag.pointerId != event.pointerId || drag.tabKey != tabKey) return;
			var tabs = latest();
			var end = tabs.onTabDragEnd;
			if (drag.dragging) {
				if (end != null) end(tabKey, event);
				event.preventDefault();
			}
			drag.clear();
			event.releasePointer();
		});
		modifier.on(UiEventKind.PointerCancel, event -> {
			if (!drag.active || drag.pointerId != event.pointerId || drag.tabKey != tabKey) return;
			var tabs = latest();
			var cancel = tabs.onTabDragCancel;
			if (drag.dragging && cancel != null) cancel(tabKey, event);
			drag.clear();
			event.releasePointer();
		});
		modifier.on(UiEventKind.KeyDown, event -> {
			if (event.key != UiKey.Escape || !drag.active) return;
			event.cancelPointerCapture();
			event.preventDefault();
		});
	}
}

private class TabDragState {
	public var active:Bool;
	public var dragging:Bool;
	public var pointerId:Int;
	public var tabKey:String;
	public var startX:Float;
	public var startY:Float;

	public function new() {
		clear();
	}

	public function clear():Void {
		active = false;
		dragging = false;
		pointerId = -1;
		tabKey = "";
		startX = 0.0;
		startY = 0.0;
	}
}

/** The strip the tabs built, as the scroll view's content. */
private class TabsStripView implements View {
	final strip:RenderNode;
	public function new(strip:RenderNode) this.strip = strip;
	public function build(context:BuildContext):ViewRoot return strip;
}

private class TabsScrollState {
	public final controller = new ScrollController();
	public var selected:String = "";
	public var width:Float = -1;
	public function new() {}
}

/** One stable tab key, accessible label, and lazily built page. */
class TabItem {
	/** Identifies the tab, as `Tabs.selectedKey` names it: required, and never empty. */
	public final key:String;

	/** The tab's name, which assistive technology announces, and its header text unless `displayLabel` is given. */
	public final label:String;

	/** Shorter header text, when the full `label` does not fit. */
	public final displayLabel:Null<String>;

	/** What the tab shows while selected. */
	public final content:View;

	/** Whether the tab can be selected. */
	public final enabled:Bool;

	/** An icon before the header text. */
	public final icon:Null<IconName>;

	/** A count shown in a badge on the header, such as unread items, when positive; it is announced with the name. */
	public final badgeCount:Int;

	/** Optional decorative view used in place of the standard icon. */
	public final iconView:Null<View>;
	/** Optional close action; the header reserves a hover-revealed close target. */
	public final onClose:Null<Void->Void>;

	/** Whether `other` describes this tab with the same inputs: the same views, and a close action or none like this one. */
	public function sameAs(other:TabItem):Bool {
		return key == other.key && label == other.label && displayLabel == other.displayLabel
			&& content == other.content
			&& enabled == other.enabled && icon == other.icon && badgeCount == other.badgeCount
			&& iconView == other.iconView && (onClose == null) == (other.onClose == null);
	}

	/** A tab named `label` showing `content`. Throws when `key` is empty or there is no content. */
	public function new(key:String, label:String, content:View, enabled:Bool = true,
			?icon:IconName, ?displayLabel:String, badgeCount:Int = 0, ?iconView:View, ?onClose:Void->Void) {
		if (key == null || key.length == 0 || content == null)
			throw "Tabs require stable keys and content views";
		this.key = key;
		this.label = label == null ? "" : label;
		this.displayLabel = displayLabel;
		this.content = content;
		this.enabled = enabled;
		this.icon = icon;
		this.badgeCount = badgeCount;
		this.iconView = iconView;
		this.onClose = onClose;
	}
}

/** Ownership of the active tab selection. */
enum TabsSelectionMode {
	/** The strip keeps the user's selection across its parent's builds. */
	Local;
	/** The caller's selectedKey is authoritative on every build. */
	Controlled;
}
