package haxeon.ui.widgets.overlays;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.TextLayout;
import haxeon.ui.TextWrap;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.theme.TextRole;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleProperty;

import haxeon.ui.Rect;
import haxeon.ui.LayoutAxis;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.Color;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.View;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;

/** Keyboard-focusable popup menu composed from ordinary Haxe buttons. */
class Menu implements View {
	final key:String;
	final items:Array<MenuItem>;
	public final x:Float;
	public final y:Float;
	public var onDismiss:Void->Void;
	public var hasDismissHandler(default, null):Bool;
	/** Keyboard invocation selects an item; pointer invocation focuses only the menu. */
	public var selectFirstOnOpen:Bool = false;

	public function new(key:String, items:Array<MenuItem>, x:Float = 0.0, y:Float = 0.0,
			?onDismiss:Void->Void) {
		this.key = key;
		this.items = items == null ? [] : items.copy();
		this.x = x;
		this.y = y;
		hasDismissHandler = onDismiss != null;
		this.onDismiss = onDismiss == null ? function() {} : onDismiss;
	}

	public function build(context:BuildContext):haxeon.ui.core.RenderNode {
		var children:Array<KeyedView> = [];
		var widestItem = 220.0;
		for (item in items) {
			if (item.separatorBefore && children.length > 0) {
				var separatorStyle = new LayoutStyle();
				separatorStyle.width = LayoutAxis.grow();
				separatorStyle.height = LayoutAxis.fixed(1);
				separatorStyle.background = context.theme.tokens.border;
				var separator = new haxeon.ui.widgets.layout.Spacer(item.key + "-separator", separatorStyle.width, separatorStyle.height);
				separator.style.background = separatorStyle.background;
				children.push(new KeyedView(item.key + "-separator", separator));
			}
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
			if (item.shortcut != null && item.shortcut.length > 0)
				button.trailingView = new Text(item.shortcut, null, context.theme.tokens.textSecondary, TextStyleOverride.text(12));
			var computed = context.resolveStyle(new StyleTarget("button", item.key, item.key,
				["menu-item", "navigation"], ["button"], 0), button.style);
			var itemStyle = computed.toLayoutStyle();
			var typography = context.resolveTextRole(TextRole.Button, TextStyleOverride.paragraph(TextWrap.None));
			var fontSource = computed.source(StyleProperty.FontSize);
			var letterSource = computed.source(StyleProperty.LetterSpacing);
			typography = typography.merge(new TextStyleOverride(null,
				fontSource != null && fontSource.layer != "framework" ? computed.get(StyleProperty.FontSize) : null,
				letterSource != null && letterSource.layer != "framework" ? computed.get(StyleProperty.LetterSpacing) : null));
			var labelStyle = TextStyleOverride.combine(TextStyleOverride.fromTextStyle(typography.textStyle),
				TextStyleOverride.foreground(item.enabled ? context.theme.tokens.textPrimary : context.theme.tokens.textDisabled));
			if (context.fonts != null) {
				var measurement = TextLayout.createStyled(context.fonts, item.label, 100000.0,
					typography.textStyle, typography.paragraphStyle);
				var shortcutWidth = 0.0;
				if (item.shortcut != null && item.shortcut.length > 0) {
					var shortcutLayout = TextLayout.createStyled(context.fonts, item.shortcut, 100000.0,
						typography.textStyle, typography.paragraphStyle);
					shortcutWidth = shortcutLayout.measure().width + 32;
					shortcutLayout.dispose();
				}
				widestItem = Math.max(widestItem, Math.ceil(measurement.measure().width + shortcutWidth) + itemStyle.padding.left + itemStyle.padding.right);
				measurement.dispose();
			}
			var label = new MiddleEllipsisText("menu-label", item.label, false, labelStyle);
			button.labelView = label;
			var tooltip = new Tooltip("menu-label-tooltip", button, new Text(item.label), 0.0, 28.0);
			tooltip.fillAnchor = true;
			tooltip.showWhen = function() return label.truncated;
			children.push(new KeyedView(item.key, tooltip));
		}
		var menuStyle = new LayoutStyle();
		// Include popup padding in the 360px cap and leave 8px at each window edge.
		var availableWidth = Math.max(1.0, Math.min(360.0, context.viewportWidth - 16.0) - 8.0);
		menuStyle.width = LayoutAxis.fixed(Math.min(widestItem, availableWidth));
		menuStyle.childGap = 2.0;
		var content = new Column("menu-items", children, menuStyle);
		var popupStyle = new LayoutStyle();
		popupStyle.background = Color.rgba(0.0, 0.0, 0.0, 0.0);
		popupStyle.padding = new Insets(4.0, 4.0, 4.0, 4.0);
		popupStyle.clipToParent = false;
		var scrollStyle = new LayoutStyle();
		scrollStyle.width = menuStyle.width;
		scrollStyle.height = LayoutAxis.fit(0.0, Math.max(1.0, context.viewportHeight - 24.0));
		var scroll = new ScrollView("menu-scroll", content, scrollStyle);
		var popup = new Popup(key, scroll, x, y, popupStyle,
			hasDismissHandler ? onDismiss : null);
		popup.anchorRectProvider = function() return new Rect(x, y, 0.0, 0.0);
		popup.label = "Menu";
		popup.menuSurface = true;
		popup.viewportMargin = 8.0;
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
		// Keep the modal keyboard owner independent of the highlighted action.
		root.focusable = !selectFirstOnOpen || focusableItems.length == 0;
		var initialFocusPending = context.state(root.id, true);
		root.onResolved(function(_) {
			if (!initialFocusPending.value) return;
			initialFocusPending.update(false);
			var initial = selectFirstOnOpen && focusableItems.length > 0 ? focusableItems[0] : root;
			context.requestFocusAfterLayout(initial.id);
		});
		root.on(UiEventKind.PointerMove, function(event) {
			var node = root.find(event.target);
			while (node != null && node != root) {
				if (node.enabled && node.semantics != null && node.semantics.role == AccessibilityRole.MenuItem) {
					context.requestFocus(node.id);
					break;
				}
				node = node.parent;
			}
		}, "capture");
		var navigate = function(event:haxeon.ui.core.UiEvent) {
			if (event.target.equals(root.id) && (event.key == UiKey.Enter || event.key == UiKey.Space)) {
				event.preventDefault();
				return;
			}
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
		};
		root.on(UiEventKind.KeyDown, navigate, "capture");
		root.on(UiEventKind.KeyRepeat, navigate, "capture");
		// Capture visits ancestors only; the neutral menu can itself be the target.
		root.on(UiEventKind.KeyDown, navigate);
		root.on(UiEventKind.KeyRepeat, navigate);
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
