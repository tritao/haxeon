package nativekit.ui.widgets.overlays;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.ButtonVariant;
import nativekit.ui.widgets.layout.Column;

import Rect;
import LayoutAxis;
import nativekit.ui.widgets.scroll.ScrollView;
import LayoutStyle;
import Insets;
import Color;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.View;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.semantics.AccessibilityAction;
import nativekit.ui.semantics.AccessibilityRole;
import nativekit.ui.semantics.AccessibilityState;
import nativekit.ui.semantics.Semantics;

/** Keyboard-focusable popup menu composed from ordinary Haxe buttons. */
class Menu implements View {
	final key:String;
	final items:Array<MenuItem>;
	public final x:Float;
	public final y:Float;
	public var onDismiss:Void->Void;
	public var hasDismissHandler(default, null):Bool;

	public function new(key:String, items:Array<MenuItem>, x:Float = 0.0, y:Float = 0.0,
			?onDismiss:Void->Void) {
		this.key = key;
		this.items = items == null ? [] : items.copy();
		this.x = x;
		this.y = y;
		hasDismissHandler = onDismiss != null;
		this.onDismiss = onDismiss == null ? function() {} : onDismiss;
	}

	public function build(context:BuildContext):nativekit.ui.core.RenderNode {
		var children:Array<KeyedView> = [];
		for (item in items) {
			var button = new Button(item.label, null, function() {
				if (item.hasSelectHandler)
					item.onSelect();
				if (hasDismissHandler)
					onDismiss();
			}, item.key);
			button.classes = ["menu-item"];
			button.variant = ButtonVariant.Navigation;
			button.enabled = item.enabled;
			button.semanticRole = AccessibilityRole.MenuItem;
			button.semanticActions = AccessibilityAction.Select;
			children.push(new KeyedView(item.key, button));
		}
		var menuStyle = new LayoutStyle();
		menuStyle.width = LayoutAxis.fixed(Math.max(1.0, Math.min(220.0, context.viewportWidth - 8.0)));
		menuStyle.childGap = 2.0;
		var content = new Column("menu-items", children, menuStyle);
		var popupStyle = new LayoutStyle();
		popupStyle.background = Color.rgba(0.0, 0.0, 0.0, 0.0);
		popupStyle.padding = new Insets(4.0, 4.0, 4.0, 4.0);
		popupStyle.clipToParent = false;
		var scrollStyle = new LayoutStyle();
		scrollStyle.width = menuStyle.width;
		scrollStyle.height = LayoutAxis.fit(0.0, Math.max(1.0, context.viewportHeight - 8.0));
		var scroll = new ScrollView("menu-scroll", content, scrollStyle);
		var popup = new Popup(key, scroll, x, y, popupStyle,
			hasDismissHandler ? onDismiss : null);
		popup.anchorRectProvider = function() return new Rect(x, y, 0.0, 0.0);
		popup.label = "Menu";
		popup.menuSurface = true;
		popup.flipHorizontally = true;
		popup.modal = true;
		popup.dimBackdrop = false;
		var root:RenderNode = popup.build(context);
		var focusableItems:Array<RenderNode> = [];
		var menuViewport:Null<RenderNode> = null;
		root.walk(function(node) {
			if (node.styleType == "scroll-view" && node.styleKey == "menu-scroll") {
				node.focusable = false;
				menuViewport = node;
			}
			if (node.semantics != null && node.semantics.role == AccessibilityRole.MenuItem && node.enabled)
				focusableItems.push(node);
		});
		if (menuViewport != null && focusableItems.length == 0) menuViewport.focusable = true;
		root.on(UiEventKind.KeyDown, function(event) {
			if (event.defaultPrevented || (event.key != UiKey.Down && event.key != UiKey.Up))
				return;
			if (focusableItems.length > 0) {
				var current = -1;
				for (index in 0...focusableItems.length)
					if (focusableItems[index].id.equals(event.target)) {
						current = index;
						break;
					}
				var next = event.key == UiKey.Down ? current + 1 : current - 1;
				if (next < 0) next = focusableItems.length - 1;
				if (next >= focusableItems.length) next = 0;
				var target = focusableItems[next];
				var viewport = menuViewport;
				var targetGeometry = target.resolved;
				var viewportGeometry = viewport == null ? null : viewport.resolved;
				if (targetGeometry != null && viewportGeometry != null) {
					var bounds = targetGeometry.viewportBounds();
					var top = viewportGeometry.viewportToLocalY(bounds.x, bounds.y);
					var bottom = viewportGeometry.viewportToLocalY(bounds.x + bounds.width, bounds.y + bounds.height);
					var offset = scroll.controller.offsetY;
					if (top < 0.0) offset += top;
					else if (bottom > scroll.controller.viewportHeight) offset += bottom - scroll.controller.viewportHeight;
					scroll.controller.jumpTo(scroll.controller.offsetX, Math.max(0.0, offset));
				}
				if (!context.requestFocus(target.id)) context.requestFocusAfterLayout(target.id);
			}
			event.preventDefault();
		}, "capture");
		var semantics = new Semantics(AccessibilityRole.Menu, "Menu");
		semantics.states |= AccessibilityState.Modal;
		if (hasDismissHandler)
			semantics.actions |= AccessibilityAction.Dismiss;
		root.semantics = semantics;
		if (hasDismissHandler)
			root.on(UiEventKind.Activate, function(event) {
				if (event.target.equals(root.id))
					onDismiss();
			});
		return root;
	}
}
