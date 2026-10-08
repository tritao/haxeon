package haxeon.ui.widgets.controls;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Color;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RetainedView;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityOrientation;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;

/** Scrollable tab strip and selected page composed from Haxe buttons and views. */
class Tabs implements View {
	final key:Key;
	public final items:Array<TabItem>;
	public var selectedKey:String;
	/** Whether selection is retained locally or supplied by the caller. */
	public var selectionMode(default, null):TabsSelectionMode;
	public final style:LayoutStyle;
	public var onChange:String->Void;
	public var hasChangeHandler(default, null):Bool;
	/** Optional pointer-drag lifecycle used by generic dock workspaces. */
	public var onTabDragStart:Null<String->UiEvent->Void>;
	public var onTabDragMove:Null<String->UiEvent->Void>;
	public var onTabDragEnd:Null<String->UiEvent->Void>;
	public var onTabDragCancel:Null<String->UiEvent->Void>;
	/** Requests a menu for an enabled tab without changing the selected page. */
	public var onTabContextMenu:Null<String->UiEvent->Void>;
	/** Called after each header is built so dock hosts can register geometry. */
	public var onTabHeaderBuilt:Null<String->RenderNode->Void>;

	/** Opt-in header retention; callers include all application-owned header inputs. */
	public var headerRevision:Null<Void->String>;
	/** Overrides the default scrolling viewport; the caller owns overflow and selected-tab reveal. */
	public var transformHeaderStrip:Null<(RenderNode, BuildContext)->RenderNode>;

	public function new(key:String, items:Array<TabItem>, selectedKey:String = "",
			?onChange:String->Void, ?style:LayoutStyle,
			?onTabDragStart:String->UiEvent->Void,
			?onTabDragMove:String->UiEvent->Void,
			?onTabDragEnd:String->UiEvent->Void,
			?onTabDragCancel:String->UiEvent->Void,
			?selectionMode:TabsSelectionMode,
			?onTabHeaderBuilt:String->RenderNode->Void) {
		this.key = new Key(key);
		this.items = items == null ? [] : items.copy();
		this.selectedKey = selectedKey == null ? "" : selectedKey;
		this.selectionMode = selectionMode == null ? TabsSelectionMode.Local : selectionMode;
		this.style = style == null ? defaultStyle() : style.copy();
		hasChangeHandler = onChange != null;
		this.onChange = onChange == null ? function(_) {} : onChange;
		this.onTabDragStart = onTabDragStart;
		this.onTabDragMove = onTabDragMove;
		this.onTabDragEnd = onTabDragEnd;
		this.onTabDragCancel = onTabDragCancel;
		this.onTabHeaderBuilt = onTabHeaderBuilt;
		this.onTabContextMenu = null;
		var keys:Map<String, Bool> = new Map();
		for (item in this.items) {
			if (item == null || keys.exists(item.key))
				throw "Tab keys must be unique";
			keys.set(item.key, true);
		}
	}

	/** Builds a tab strip with named options for optional drag behavior. */
	public static function withOptions(key:String, items:Array<TabItem>, selectedKey:String,
			onChange:Null<String->Void>, options:TabsOptions):Tabs {
		var configured = options == null ? new TabsOptions() : options;
		var tabs = new Tabs(key, items, selectedKey, onChange, configured.style,
			configured.onTabDragStart, configured.onTabDragMove, configured.onTabDragEnd,
			configured.onTabDragCancel, configured.selectionMode, configured.onTabHeaderBuilt);
		tabs.onTabContextMenu = configured.onTabContextMenu;
		return tabs;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var state:State<String> = context.state(context.id("selected-tab"), selectedKey);
			var active:String = selectionMode == TabsSelectionMode.Controlled ?
				selectedKey : state.value;
			if (!isEnabled(active))
				active = firstEnabled();
			if (active != state.value)
				state.update(active);
			selectedKey = active;
			var select = function(next:String) {
				if (next == selectedKey)
					return;
				selectedKey = next;
				state.update(next);
				if (hasChangeHandler)
					onChange(next);
			};

			var rootId = context.id("tabs");
			var rootFlags = context.interactionStates.get(rootId);
			var rootComputed = context.styleResolver.resolve(
				new StyleTarget("tabs", key.value, key.value, null, ["tabs"], rootFlags),
				context.inheritedStyle, context.theme.styles, context.styleSheet, style, context.environment);
			var root = new RenderNode(rootId, LayoutVisualKind.Box, rootComputed.toLayoutStyle());
			root.setStyleIdentity("tabs", key.value, key.value, null, ["tabs"]);
			root.states = rootFlags;
			root.computedStyle = rootComputed;
			var tabsSemantics = new Semantics(AccessibilityRole.TabList, "Tabs");
			tabsSemantics.orientation = AccessibilityOrientation.Horizontal;
			root.semantics = tabsSemantics;
			var stripView = new TabsStripView(function(buildContext) {
				var strip = buildStrip(buildContext, rootComputed, active, select);
				var transform:Null<(RenderNode, BuildContext)->RenderNode> = transformHeaderStrip;
				return transform == null ? scrollStrip(strip, buildContext, active) : transform(strip, buildContext);
			});
			var revision:Null<Void->String> = headerRevision;
			var strip = revision == null ? stripView.build(context) :
				new RetainedView("tab-headers", function(_) return stripView,
					function() return active.length + ":" + active + revision()).build(context);
			root.add(strip);

			var selectedItem:Null<TabItem> = null;
			for (item in items)
				if (item.key == active) {
					selectedItem = item;
					break;
				}
			if (selectedItem != null) {
				var item:TabItem = cast selectedItem;
				var panel = context.withScope(new Key("panel:" + item.key), function() {
					var panelStyle = new LayoutStyle();
					panelStyle.width = LayoutAxis.stretch();
					panelStyle.height = LayoutAxis.grow();
					var node = new RenderNode(context.id("tab-panel"), LayoutVisualKind.Box,
						panelStyle);
					node.semantics = new Semantics(AccessibilityRole.TabPanel, item.label);
					var content = context.withStyleParent(rootComputed, function() {
						return context.withScope(new Key("content"),
							function() return item.content.build(context));
					});
					content.layout.style.width = LayoutAxis.stretch();
					node.add(content);
					return node;
				});
				root.add(panel);
			}
			return root;
		});
	}

	function buildStrip(context:BuildContext, rootComputed:ComputedStyle, active:String,
			select:String->Void):RenderNode {
		var stripStyle = new LayoutStyle();
		stripStyle.width = LayoutAxis.grow();
		stripStyle.direction = LayoutDirection.LeftToRight;
		stripStyle.childGap = 4.0;
		var strip = new RenderNode(context.id("tab-strip"), LayoutVisualKind.Box, stripStyle);
		var buttonNodes:Array<RenderNode> = [];
		var tabDragState:Null<State<TabDragState>> = null;
		if (onTabDragStart != null || onTabDragMove != null || onTabDragEnd != null ||
			onTabDragCancel != null)
			tabDragState = context.state(context.id("tab-drag"), new TabDragState());
		for (item in items) {
			var button = new Button(item.displayLabel == null ? item.label : item.displayLabel,
				null, null, item.key);
			button.onClickEvent = function(event) {
				if (event.kind == UiEventKind.Activate || event.button == 0) select(item.key);
			};
			button.accessibilityLabel = item.label + (item.badgeCount > 0 ? ", " + item.badgeCount : "");
				if (item.badgeCount > 0) button.trailingView = new CountBadge(item.badgeCount);
			button.variant = ButtonVariant.Navigation;
			button.classes = ["tab-header"];
			button.leadingIcon = item.icon;
			button.leadingView = item.iconView;
			button.iconSize = 14.0;
			button.enabled = item.enabled;
			button.selected = item.key == active;
			button.semanticRole = AccessibilityRole.Tab;
			button.semanticActions = AccessibilityAction.Select;
			var buttonNode = context.withStyleParent(rootComputed, function() {
				return context.withScope(new Key(item.key),
				function() return button.build(context));
			});
			var headerStyle = new LayoutStyle();
			headerStyle.direction = LayoutDirection.TopToBottom;
			var header = new RenderNode(context.id("tab-header:" + item.key),
				LayoutVisualKind.Box, headerStyle);
			header.hitTestSelf = false;
			if (item.enabled && item.onClose != null) header.on(UiEventKind.Click, function(event) {
				if (event.button != 2) return;
				event.preventDefault();
				event.stopPropagation();
				var close = item.onClose;
				if (close != null) close();
			}, "capture");
			header.add(item.onClose == null ? buttonNode : buildClosableHeader(context, item, buttonNode));
			var indicatorStyle = new LayoutStyle();
			indicatorStyle.width = LayoutAxis.grow();
			indicatorStyle.height = LayoutAxis.fixed(2.0);
			indicatorStyle.background = item.key == active ? context.theme.tokens.accent :
				Color.rgba(0.0, 0.0, 0.0, 0.0);
			var indicator = new RenderNode(context.id("tab-indicator:" + item.key),
				LayoutVisualKind.Box, indicatorStyle);
			indicator.hitTestSelf = false;
			header.add(indicator);
			strip.add(header);
			buttonNodes.push(buttonNode);
			if (onTabHeaderBuilt != null)
				onTabHeaderBuilt(item.key, buttonNode);
			installTabDragHandlers(buttonNode, item.key, tabDragState);
			if (item.enabled && onTabContextMenu != null) {
				var requestMenu = function(event:UiEvent) {
				var handler = onTabContextMenu;
				if (handler == null) return;
				handler(item.key, event);
				event.preventDefault();
				event.stopPropagation();
				};
				buttonNode.on(UiEventKind.PointerDown, function(event) {
				if (event.button == 1) requestMenu(event);
				});
				buttonNode.on(UiEventKind.KeyDown, function(event) {
				if (UiKey.isContextMenuRequest(event.key, event.modifiers))
					requestMenu(event);
				});
			}
		}
		for (index in 0...buttonNodes.length) {
			var tabIndex = index;
			buttonNodes[index].on(UiEventKind.KeyDown, function(event) {
				var direction = event.key == UiKey.Right || event.key == UiKey.Down ? 1 :
				event.key == UiKey.Left || event.key == UiKey.Up ? -1 : 0;
				if (direction == 0 || buttonNodes.length == 0)
				return;
				var nextIndex = tabIndex;
				for (_ in 0...buttonNodes.length) {
				nextIndex = (nextIndex + direction + buttonNodes.length) % buttonNodes.length;
				if (items[nextIndex].enabled)
					break;
				}
				if (items[nextIndex].enabled) {
				select(items[nextIndex].key);
				context.requestFocus(buttonNodes[nextIndex].id);
				event.preventDefault();
				}
			});
		}
		return strip;
	}

	/** Keep intrinsic header widths; overflow belongs to a clipped viewport, not the labels. */
	function scrollStrip(strip:RenderNode, context:BuildContext, active:String):RenderNode {
		var state = context.state(context.id("tab-scroll-state"), new TabsScrollState()).value;
		strip.layout.style.width = LayoutAxis.fit();
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		var scroll = new ScrollView("tab-viewport",
			new TabsStripView(function(_) return strip), style,
			ScrollAxis.Horizontal, state.controller);
		scroll.showScrollbar = false;
		scroll.onScroll = function(event) {
			if (event.deltaX == 0 && state.controller.scrollBy(event.deltaY, 0)) {
				event.preventDefault();
				event.stopPropagation();
			}
		};
		var viewport = scroll.build(context);
		for (index in 0...items.length) if (items[index].key == active) {
			var header = strip.children[index];
			// ScrollView updates metrics before resolving the header. Geometry is
			// untransformed here, so compare against the controller's current offset.
			header.onResolved(function(tab) {
				if (viewport.resolved == null) return;
				var bounds = viewport.resolved;
				var left = tab.x - bounds.x;
				if (state.selected == active && state.width == bounds.width &&
					state.left == left && state.tabWidth == tab.width) return;
				state.selected = active; state.width = bounds.width;
				state.left = left; state.tabWidth = tab.width;
				var next = state.controller.offsetX;
				if (tab.width > bounds.width || left < next) next = left;
				else if (left + tab.width > next + bounds.width) next = left + tab.width - bounds.width;
				if (state.controller.jumpTo(next, 0)) context.requestLayoutFeedback();
			});
		}
		return viewport;
	}

	function buildClosableHeader(context:BuildContext, item:TabItem, buttonNode:RenderNode):RenderNode {
		var rowStyle = new LayoutStyle();
		rowStyle.direction = LayoutDirection.LeftToRight;
		rowStyle.childAlignY = LayoutAlignmentY.Center;
		rowStyle.background = buttonNode.layout.style.background;
		var row = new RenderNode(context.id("tab-actions:" + item.key), LayoutVisualKind.Box, rowStyle);
		row.hitTestSelf = false;
		row.add(buttonNode);
		var hover = context.state(context.id("tab-close-hover:" + item.key), false);
		var focused = context.state(context.id("tab-close-focus:" + item.key), false);
		var slotStyle = new LayoutStyle();
		slotStyle.width = LayoutAxis.fixed(28);
		slotStyle.height = LayoutAxis.fixed(24);
		var slot = new RenderNode(context.id("tab-close-slot:" + item.key), LayoutVisualKind.Box, slotStyle);
		slot.hitTestSelf = true;
		var closeStyle = new LayoutStyle();
		closeStyle.width = LayoutAxis.fixed(24);
		closeStyle.height = LayoutAxis.fixed(24);
		closeStyle.padding = new Insets(4, 4, 4, 4);
		var close = new Button("", closeStyle, null, "tab-close:" + item.key);
		close.leadingIcon = haxeon.ui.icons.IconName.Close;
		close.iconSize = 14;
		close.variant = ButtonVariant.Navigation;
		close.classes = ["tab-close"];
		close.enabled = item.enabled;
		close.accessibilityLabel = "Close " + item.label;
		close.onClickEvent = function(event) {
			event.stopPropagation();
			var handler = item.onClose;
			if ((event.kind == UiEventKind.Activate || event.button == 0) && handler != null) handler();
		};
		var closeNode = close.build(context);
		closeNode.on(UiEventKind.PointerDown, function(event) event.stopPropagation());
		closeNode.on(UiEventKind.PointerUp, function(event) event.stopPropagation());
		var refresh = function() { closeNode.layout.style.visible = hover.value || focused.value; };
		refresh();
		row.on(UiEventKind.HoverEnter, function(event) {
			if (event.target.equals(row.id)) { hover.update(true); refresh(); }
		});
		row.on(UiEventKind.HoverLeave, function(event) {
			if (event.target.equals(row.id)) { hover.update(false); refresh(); }
		});
		for (node in [buttonNode, closeNode]) {
			node.on(UiEventKind.Focus, function(_) { focused.update(true); refresh(); });
			node.on(UiEventKind.Blur, function(_) { focused.update(false); refresh(); });
		}
		slot.add(closeNode);
		row.add(slot);
		return row;
	}

	function isEnabled(key:String):Bool {
		for (item in items)
			if (item.enabled && item.key == key)
				return true;
		return false;
	}

	function firstEnabled():String {
		for (item in items)
			if (item.enabled)
				return item.key;
		return "";
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.direction = LayoutDirection.TopToBottom;
		result.childGap = 8.0;
		return result;
	}

	function installTabDragHandlers(buttonNode:RenderNode, tabKey:String,
			dragState:Null<State<TabDragState>>):Void {
		if (dragState == null)
			return;
		buttonNode.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0)
				return;
			var drag = dragState.value;
			drag.active = true;
			drag.dragging = false;
			drag.pointerId = event.pointerId;
			drag.tabKey = tabKey;
			drag.startX = event.x;
			drag.startY = event.y;
			dragState.update(drag);
			// Dock targets stay inside the workspace. Logical capture keeps the
			// drag routed to this tab without grabbing the native window pointer.
			event.capturePointer(false);
		});
		buttonNode.on(UiEventKind.PointerMove, function(event) {
			var drag = dragState.value;
			if (!drag.active || drag.pointerId != event.pointerId || drag.tabKey != tabKey)
				return;
			var dx = event.x - drag.startX;
			var dy = event.y - drag.startY;
			if (!drag.dragging && dx * dx + dy * dy >= 36.0) {
				drag.dragging = true;
				dragState.update(drag);
				if (onTabDragStart != null)
					onTabDragStart(tabKey, event);
			}
			if (drag.dragging) {
				if (onTabDragMove != null)
					onTabDragMove(tabKey, event);
				event.preventDefault();
			}
		});
		buttonNode.on(UiEventKind.PointerUp, function(event) {
			var drag = dragState.value;
			if (!drag.active || drag.pointerId != event.pointerId || drag.tabKey != tabKey)
				return;
			if (drag.dragging) {
				if (onTabDragEnd != null)
					onTabDragEnd(tabKey, event);
				event.preventDefault();
			}
			drag.clear();
			dragState.update(drag);
			event.releasePointer();
		});
		buttonNode.on(UiEventKind.PointerCancel, function(event) {
			var drag = dragState.value;
			if (!drag.active || drag.pointerId != event.pointerId || drag.tabKey != tabKey)
				return;
			if (drag.dragging && onTabDragCancel != null)
				onTabDragCancel(tabKey, event);
			drag.clear();
			dragState.update(drag);
			event.releasePointer();
		});
		buttonNode.on(UiEventKind.KeyDown, function(event) {
			var drag = dragState.value;
			if (event.key != UiKey.Escape || !drag.active)
				return;
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

private class TabsStripView implements View {
	final buildStrip:BuildContext->RenderNode;
	public function new(buildStrip:BuildContext->RenderNode) this.buildStrip = buildStrip;
	public function build(context:BuildContext):RenderNode return buildStrip(context);
}

private class TabsScrollState {
	public final controller = new ScrollController();
	public var selected:String = "";
	public var width:Float = -1;
	public var left:Float = -1;
	public var tabWidth:Float = -1;
	public function new() {}
}
