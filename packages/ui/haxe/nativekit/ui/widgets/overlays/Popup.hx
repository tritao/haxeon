package nativekit.ui.widgets.overlays;

import Color;
import LayoutAxis;
import LayoutPositioning;
import LayoutStyle;
import LayoutVisualKind;
import Rect;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.View;
import nativekit.ui.semantics.AccessibilityRole;
import nativekit.ui.semantics.Semantics;
import nativekit.ui.style.StyleProperty;
import nativekit.ui.style.StyleSource;
import nativekit.ui.style.StyleTarget;

/** Parent-sized popup layer with optional modal focus and outside-click dismissal. */
class Popup implements View {
	final key:Key;
	final child:View;
	public final x:Float;
	public final y:Float;
	public final style:LayoutStyle;
	/** Optional live anchor in logical screen coordinates; placement uses measured panel size. */
	public var anchorRectProvider:Null<Void->Null<Rect>>;
	public var label:Null<String>;
	public var modal:Bool;
	public var dimBackdrop:Bool;
	public var dismissOnOutside:Bool;
	public var dismissOnEscape:Bool;
	public var backdropColor:Null<Color>;
	/** Absolute layer shared by the backdrop; content paints one layer above it. */
	public var layerZIndex:Int;
	/** Paint a square menu surface and its shadow beneath the popup content. */
	public var menuSurface:Bool;
	/**
	 * Open to the left of the anchor when the popup does not fit to its right
	 * but fits to its left, as native context menus do. Otherwise the popup is
	 * shifted to stay inside the layer.
	 */
	public var flipHorizontally:Bool;
	public var onDismiss:Void->Void;
	public var hasDismissHandler(default, null):Bool;
	public function new(key:String, child:View, x:Float = 0.0, y:Float = 0.0,
			?style:LayoutStyle, ?onDismiss:Void->Void) {
		if (child == null || !finite(x) || !finite(y))
			throw "Popup requires content and a finite parent-relative position";
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
		this.onDismiss = onDismiss == null ? function() {} : onDismiss;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var rootStyle = new LayoutStyle();
			rootStyle.width = LayoutAxis.grow();
			rootStyle.height = LayoutAxis.grow();
			var rootId = context.id("popup-layer");
			var rootComputed = context.resolveStyle(
				new StyleTarget("popup", key.value, key.value, null, ["popup"],
					context.interactionStates.get(rootId)), rootStyle);
			var root = new RenderNode(rootId, LayoutVisualKind.Box, rootComputed.toLayoutStyle());
			root.setStyleIdentity("popup", key.value, key.value, null, ["popup"]);
			root.states = context.interactionStates.get(rootId);
			root.computedStyle = rootComputed;
			root.hitTestSelf = false;
			root.focusTrap = modal;
			if (label != null)
				root.semantics = new Semantics(AccessibilityRole.Group, label);

			var backdropStyle = new LayoutStyle();
			backdropStyle.width = LayoutAxis.grow();
			backdropStyle.height = LayoutAxis.grow();
			backdropStyle.positioning = LayoutPositioning.Absolute;
			backdropStyle.zIndex = layerZIndex;
			backdropStyle.visible = modal || dismissOnOutside;
			var color = backdropColor == null ? context.theme.overlayBackdrop : cast backdropColor;
			backdropStyle.background = modal && dimBackdrop
				? color : Color.rgba(0.0, 0.0, 0.0, 0.0);
			var backdropId = context.id("backdrop");
			var backdropComputed = context.resolveStyle(
				new StyleTarget("popup-backdrop", "backdrop", "backdrop", null, ["popup"],
					context.interactionStates.get(backdropId)), backdropStyle);
			if (!modal || !dimBackdrop)
				backdropComputed.set(StyleProperty.Background,
					Color.rgba(0.0, 0.0, 0.0, 0.0),
					new StyleSource("local", "popup-backdrop", -1, "local"));
			var backdrop = new RenderNode(backdropId, LayoutVisualKind.Box,
				backdropComputed.toLayoutStyle());
			backdrop.setStyleIdentity("popup-backdrop", "backdrop", "backdrop", null, ["popup"]);
			backdrop.states = context.interactionStates.get(backdropId);
			backdrop.computedStyle = backdropComputed;
			if (dismissOnOutside && hasDismissHandler)
				backdrop.on(UiEventKind.Click, function(event) {
				onDismiss();
				event.stopPropagation();
			});
			root.add(backdrop);

			var panelStyle = style.copy();
			panelStyle.positioning = LayoutPositioning.Absolute;
			panelStyle.positionX = x;
			panelStyle.positionY = y;
			panelStyle.zIndex = layerZIndex + 1;
			var panelId = context.id("popup-content");
			var panelComputed = context.resolveStyle(
				new StyleTarget("popup-content", key.value, key.value, null, ["popup"],
					context.interactionStates.get(panelId)), panelStyle);
			if (menuSurface) {
				var source = new StyleSource("local", "popup-content", -1, "local");
				panelComputed.set(StyleProperty.Background, Color.rgba(0.0, 0.0, 0.0, 0.0), source);
				panelComputed.set(StyleProperty.Padding, panelStyle.padding, source);
				panelComputed.set(StyleProperty.RadiusTopLeft, 0.0, source);
				panelComputed.set(StyleProperty.RadiusTopRight, 0.0, source);
				panelComputed.set(StyleProperty.RadiusBottomRight, 0.0, source);
				panelComputed.set(StyleProperty.RadiusBottomLeft, 0.0, source);
			}
			var panel = new RenderNode(panelId, LayoutVisualKind.Box,
				panelComputed.toLayoutStyle());
			panel.setStyleIdentity("popup-content", key.value, key.value, null, ["popup"]);
			panel.states = context.interactionStates.get(panelId);
			panel.computedStyle = panelComputed;
			if (menuSurface) {
				var surfaceStyle = new LayoutStyle();
				surfaceStyle.width = LayoutAxis.grow();
				surfaceStyle.height = LayoutAxis.grow();
				surfaceStyle.positioning = LayoutPositioning.Absolute;
				surfaceStyle.zIndex = -1;
				surfaceStyle.clipToParent = false;
				var surface = new RenderNode(context.id("popup-surface"),
					LayoutVisualKind.Custom, surfaceStyle);
				surface.hitTestSelf = false;
				var background = context.theme.tokens.navigationBackground;
				var border = context.theme.tokens.border;
				surface.onPaint(function(canvas, geometry) {
					var width = geometry.width;
					var height = geometry.height;
					canvas.fillRectIfPositive(new Rect(0.0, 0.0, width, height), background);
					canvas.fillRectIfPositive(new Rect(0.0, 0.0, width, 1.0), border);
					canvas.fillRectIfPositive(new Rect(0.0, height - 1.0, width, 1.0), border);
					canvas.fillRectIfPositive(new Rect(0.0, 1.0, 1.0, height - 2.0), border);
					canvas.fillRectIfPositive(new Rect(width - 1.0, 1.0, 1.0,
							height - 2.0), border);
				});
				panel.add(surface);
				var shadowStyle = new LayoutStyle();
				shadowStyle.width = LayoutAxis.grow();
				shadowStyle.height = LayoutAxis.grow();
				shadowStyle.positioning = LayoutPositioning.Absolute;
				shadowStyle.zIndex = layerZIndex + 1;
				var shadowLayer = new RenderNode(context.id("popup-shadow"),
					LayoutVisualKind.Custom, shadowStyle);
				shadowLayer.hitTestSelf = false;
				var shadow = context.theme.tokens.selectionPopupShadow;
				// A soft key shadow lifts the menu; a tight contact shadow at half
				// strength defines its edge against similarly coloured content.
				var contactShadow = Color.rgba(shadow.red, shadow.green, shadow.blue,
					shadow.alpha * 0.5);
				shadowLayer.onPaint(function(canvas, geometry) {
					var bounds = panel.resolved;
					if (bounds == null) return;
					var rect = new Rect(bounds.x - geometry.x, bounds.y - geometry.y,
						bounds.width, bounds.height);
					var square = [0.0, 0.0, 0.0, 0.0];
					canvas.drawBoxShadow(rect, 0.0, 6.0, 20.0, 0.0, square, shadow);
					canvas.drawBoxShadow(rect, 0.0, 1.0, 3.0, 0.0, square, contactShadow);
				});
				root.add(shadowLayer);
			}
			var content = context.withStyleParent(panelComputed, function() return
				context.withScope(new Key("content"), function() return child.build(context)));
			if (anchorRectProvider != null)
				panel.onResolved(function(geometry) {
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
					if (top + geometry.height > bounds.height)
						top = anchor.y - bounds.y - geometry.height;
					left = Math.max(0.0, Math.min(left, bounds.width - geometry.width));
					top = Math.max(0.0, Math.min(top, bounds.height - geometry.height));
					if (Math.abs(panel.layout.style.positionX - left) > 0.01 ||
						Math.abs(panel.layout.style.positionY - top) > 0.01) {
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

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}
