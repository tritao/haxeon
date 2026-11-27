package haxeon.ui.widgets.overlays;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.ComputedStyle;

/** Parent-sized popup layer with optional modal focus and outside-click dismissal. */
class Popup implements View {
	final key:Key;
	final child:View;

	/** Its left edge, in its parent's coordinates. */
	public final x:Float;

	/** Its top edge, in its parent's coordinates. */
	public final y:Float;

	/** The popup's box. */
	public final style:LayoutStyle;
	/** Optional live anchor in logical screen coordinates; placement uses measured panel size. */
	public var anchorRectProvider:Null<Void->Null<Rect>>;

	/** The popup's accessible name. */
	public var label:Null<String>;

	/** Whether it keeps keyboard focus within itself. */
	public var modal:Bool;

	/** Whether the rest of the UI is dimmed behind it. */
	public var dimBackdrop:Bool;

	/** Whether a click outside it dismisses it. */
	public var dismissOnOutside:Bool;

	/** Whether Escape dismisses it. */
	public var dismissOnEscape:Bool;

	/** The color of the dimmed backdrop; the theme's when null. */
	public var backdropColor:Null<Color>;
	/** Absolute layer shared by the backdrop; content paints one layer above it. */
	public var layerZIndex:Int;
	/** Paint a square menu surface and its shadow beneath the popup content. */
	public var menuSurface:Bool;
	/** Space kept between an anchored popup and the window edges. */
	public var viewportMargin:Float = 0.0;
	/**
	 * Open to the left of the anchor when the popup does not fit to its right
	 * but fits to its left, as native context menus do. Otherwise the popup is
	 * shifted to stay inside the layer.
	 */
	public var flipHorizontally:Bool;
	/** Handle an outside click (for example, a sibling menu trigger); true skips default dismissal. */
	public var onOutsideClick:Null<UiEvent->Bool> = null;

	/** Called when the user dismisses it; the caller removes it. */
	public var onDismiss:Void->Void;
	internal var hasDismissHandler(default, null):Bool;

	/**
	 * A popup showing `child` at (`x`, `y`) in its parent. Throws without content or with a position that is not
	 * finite.
	 */
	public function new(key:String,
			child:View, x:Float = 0.0, y:Float = 0.0, ?style:LayoutStyle, ?onDismiss:Void->Void) {
		if (child == null || !finite(x)
			|| !finite(y)) throw "Popup requires content and a finite parent-relative position";
		this.key = new Key(key);
		this.child = child;
		this.x = x;
		this.y = y;
		this.style = style == null ? new LayoutStyle() : style.copy();
		label = null;
		anchorRectProvider = null;
		modal = true;
		dimBackdrop = true;
		dismissOnOutside = true;
		dismissOnEscape = true;
		backdropColor = null;
		layerZIndex = 0;
		menuSurface = false;
		flipHorizontally = false;
		hasDismissHandler = onDismiss != null;
		this.onDismiss = onDismiss == null ? function() {}
			: onDismiss;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, function() {
			var rootStyle = new LayoutStyle();
			rootStyle.width = LayoutAxis.grow();
			rootStyle.height = LayoutAxis.grow();
			rootStyle.positioning = LayoutPositioning.Absolute;
			rootStyle.overlay = true;
			rootStyle.zIndex = layerZIndex;
			var rootId = context.rootId("popup-layer");
			var root = context.styled(rootId, LayoutVisualKind.Box,
				new StyleIdentity("popup", key.rawValue, key.rawValue, null, ["popup"]), rootStyle);
			root.hitTestSelf = false;
			root.focusTrap = modal;
			if (label != null) root.semantics = new Semantics(AccessibilityRole.Group, label);

			var backdropStyle = new LayoutStyle();
			backdropStyle.width = LayoutAxis.grow();
			backdropStyle.height = LayoutAxis.grow();
			backdropStyle.positioning = LayoutPositioning.Absolute;
			backdropStyle.zIndex = layerZIndex;
			backdropStyle.visible = modal || dismissOnOutside;
			var color = backdropColor == null ? context.theme.tokens.overlayBackdrop : cast backdropColor;
			backdropStyle.background = modal && dimBackdrop ? color : Color.rgba(0.0, 0.0, 0.0, 0.0);
			var backdropId = context.id("backdrop");
			var backdropIdentity = new StyleIdentity("popup-backdrop", "backdrop", "backdrop", null, ["popup"]);
			var backdropComputed = context.resolveStyled(backdropId, backdropIdentity, backdropStyle);
			if (!modal || !dimBackdrop) backdropComputed.setColor(StyleProperty.Background,
				Color.rgba(0.0, 0.0, 0.0, 0.0),
				new StyleSource("local", "popup-backdrop", -1, "local"));
			var backdrop = context.createNode(backdropId, LayoutVisualKind.Box, backdropComputed.toLayoutStyle());
			context.applyStyled(backdrop, backdropIdentity, backdropComputed);
			if (dismissOnOutside && (hasDismissHandler || onOutsideClick != null)) backdrop.on(UiEventKind.Click,
				function(event) {
					if (onOutsideClick == null || !onOutsideClick(event)) onDismiss();
					event.stopPropagation();
				});
			root.add(backdrop);

			var panelStyle = style.copy();
			panelStyle.positioning = LayoutPositioning.Absolute;
			panelStyle.positionX = x;
			panelStyle.positionY = y;
			panelStyle.zIndex = layerZIndex + 1;
			var panelId = context.id("popup-content");
			var panelIdentity = new StyleIdentity("popup-content", key.rawValue, key.rawValue, null, ["popup"]);
			var panelComputed = context.resolveStyled(panelId, panelIdentity, panelStyle);
			if (menuSurface) {
				var source = new StyleSource("local", "popup-content", -1, "local");
				panelComputed.setColor(StyleProperty.Background, Color.rgba(0.0, 0.0, 0.0, 0.0), source);
				panelComputed.setInsets(StyleProperty.Padding, panelStyle.padding, source);
				panelComputed.setNumber(StyleProperty.RadiusTopLeft, 0.0, source);
				panelComputed.setNumber(StyleProperty.RadiusTopRight, 0.0, source);
				panelComputed.setNumber(StyleProperty.RadiusBottomRight, 0.0, source);
				panelComputed.setNumber(StyleProperty.RadiusBottomLeft, 0.0, source);
			}
			var panel = context.createNode(panelId, LayoutVisualKind.Box, panelComputed.toLayoutStyle());
			context.applyStyled(panel, panelIdentity, panelComputed);
			if (menuSurface) {
				var surfaceStyle = new LayoutStyle();
				surfaceStyle.width = LayoutAxis.grow();
				surfaceStyle.height = LayoutAxis.grow();
				surfaceStyle.positioning = LayoutPositioning.Absolute;
				surfaceStyle.zIndex = -1;
				surfaceStyle.clipToParent = false;
				var surface = context.createNode(context.rootId("popup-surface"), LayoutVisualKind.Custom,
					surfaceStyle);
				surface.hitTestSelf = false;
				var background = context.theme.tokens.surface;
				var border = context.theme.tokens.border;
				surface.onPaint(function(canvas, geometry) {
					var width = geometry.width;
					var height = geometry.height;
					if (width <= 2.0 || height <= 2.0) return;
					canvas.fillRoundedRect(new Rect(0.0, 0.0, width, height), 6.0, border);
					canvas.fillRoundedRect(new Rect(1.0, 1.0, width - 2.0, height - 2.0), 5.0, background);
				});
				panel.add(surface);
				var shadowStyle = new LayoutStyle();
				shadowStyle.width = LayoutAxis.grow();
				shadowStyle.height = LayoutAxis.grow();
				shadowStyle.positioning = LayoutPositioning.Absolute;
				shadowStyle.zIndex = layerZIndex + 1;
				var shadowLayer = context.createNode(context.rootId("popup-shadow"), LayoutVisualKind.Custom,
					shadowStyle);
				shadowLayer.hitTestSelf = false;
				var shadow = context.theme.tokens.selectionPopupShadow;
				// A soft key shadow lifts the menu; a tight contact shadow at half
				// strength defines its edge against similarly coloured content.
				var contactShadow = Color.rgba(shadow.red, shadow.green, shadow.blue, shadow.alpha * 0.5);
				shadowLayer.onPaint(function(canvas, geometry) {
					var bounds = panel.resolved;
					if (bounds == null) return;
					var rect = new Rect(bounds.x - geometry.x, bounds.y - geometry.y, bounds.width, bounds.height);
					var corners = [6.0, 6.0, 6.0, 6.0];
					canvas.drawBoxShadow(rect, 0.0, 6.0, 20.0, 0.0, corners, shadow);
					canvas.drawBoxShadow(rect, 0.0, 1.0, 3.0, 0.0, corners, contactShadow);
				});
				root.add(shadowLayer);
			}
			var content = context.withStyleParent(panelComputed,
				function() return context.withScope(new Key("content"), function() return child.build(context)));
			if (anchorRectProvider != null) panel.onResolved(function(geometry) {
				var bounds = root.resolved;
				var provider = anchorRectProvider;
				if (provider == null) return;
				var anchor = provider();
				if (bounds == null || anchor == null) return;
				var left = anchor.x - bounds.x;
				var top = anchor.y + anchor.height - bounds.y;
				if (flipHorizontally && left + geometry.width > bounds.width) {
					var flipped = anchor.x + anchor.width - bounds.x - geometry.width;
					if (flipped >= 0.0) left = flipped;
				}
				if (top + geometry.height > bounds.height) top = anchor.y - bounds.y - geometry.height;
				var margin = Math.max(0.0, viewportMargin);
				left = Math.max(margin, Math.min(left, bounds.width - geometry.width - margin));
				top = Math.max(margin, Math.min(top, bounds.height - geometry.height - margin));
				if (Math.abs(panel.layout.style.positionX - left) > 0.01
					|| Math.abs(panel.layout.style.positionY - top) > 0.01) {
					context.willEditRetained(panel);
					panel.layout.style.positionX = left;
					panel.layout.style.positionY = top;
					context.requestLayoutFeedback();
				}
			});
			panel.add(content);
			root.add(panel);
			root.on(UiEventKind.KeyDown, function(event) {
				if (event.key == UiKey.Escape && dismissOnEscape && hasDismissHandler) {
					event.preventDefault();
					onDismiss();
				}
			});
			return root;
		});
	}

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;
}
