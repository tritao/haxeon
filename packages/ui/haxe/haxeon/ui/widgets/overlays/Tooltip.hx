package haxeon.ui.widgets.overlays;

import haxeon.ui.LayoutAxis;
import haxeon.ui.Rect;
import haxeon.ui.Insets;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleTarget;

/** Hover-triggered tooltip layered above its anchor with persistent Haxe state. */
class Tooltip implements View {
	/** Preferred side. Null preserves explicit x/y positioning. */
	public var placement:Null<TooltipPlacement> = null;
	/** Initial hover delay for side-positioned tooltips. */
	public var delaySeconds:Float = 0.8;
	public var hoverGroup:Null<TooltipHoverGroup> = null;
	public var groupVisible:Bool = false;
	public var boundsProvider:Null<Void->Rect> = null;
	public var startAtAnchorMiddle:Bool = false;
	static inline final PADDING = 10.0;
	static inline final EDGE = 6.0;

	final key:Key;
	final anchor:View;
	final content:View;
	public final x:Float;
	public final y:Float;
	/** Fill the available row width when the anchor needs to clip long text. */
	public var fillAnchor:Bool = false;
	/** Optional condition checked when the pointer enters the anchor. */
	public var showWhen:Null<Void->Bool> = null;
	/** Require pointer motion over the anchor, rather than layout-induced hover. */
	public var requirePointerMovement:Bool = false;
	/** Change this value to dismiss a tooltip when its surrounding content moves. */
	public var dismissRevision:Int = 0;

	public function new(key:String, anchor:View, content:View, x:Float = 0.0, y:Float = -28.0) {
		if (anchor == null || content == null)
			throw "Tooltip requires an anchor and content view";
		this.key = new Key(key);
		this.anchor = anchor;
		this.content = content;
		this.x = x;
		this.y = y;
	}

	public function build(context:BuildContext):RenderNode {
		if (placement != null) return buildPositioned(context);
		return context.withScope(key, function() {
			var state:State<Bool> = context.state(context.id("visible"), false);
			var pointer = context.resourceState(context.id("pointer-state"), function() return new TooltipPointerState(), function(_) {}).value;
			if (pointer.dismissRevision != dismissRevision) {
				pointer.dismissRevision = dismissRevision;
				if (state.value) state.update(false);
			}
			var tooltipStyle = new LayoutStyle();
			tooltipStyle.positioning = LayoutPositioning.Absolute;
			tooltipStyle.positionX = x;
			tooltipStyle.positionY = y;
			tooltipStyle.zIndex = 10;
			tooltipStyle.clipToParent = false;
			tooltipStyle.visible = cast state.value;
			var tooltip = new AnonymousTooltipContent(content, tooltipStyle);
			var rootStyle = new LayoutStyle();
			rootStyle.width = fillAnchor ? LayoutAxis.grow() : LayoutAxis.fit();
			rootStyle.height = LayoutAxis.fit();
			rootStyle.clipToParent = false;
			var root = context.withScope(new Key("layers"), function() {
				var rootId = context.id("stack");
				var rootComputed = context.resolveStyle(
					new StyleTarget("tooltip-layer", key.value, key.value, null, ["tooltip-layer"],
						context.interactionStates.get(rootId)), rootStyle);
				var result = new RenderNode(rootId, LayoutVisualKind.Box, rootComputed.toLayoutStyle());
				result.setStyleIdentity("tooltip-layer", key.value, key.value, null, ["tooltip-layer"]);
				result.states = context.interactionStates.get(rootId);
				result.computedStyle = rootComputed;
				var anchorNode = context.withStyleParent(rootComputed, function() return
					context.withScope(new Key("anchor"), function() return anchor.build(context)));
				var tooltipNode = context.withStyleParent(rootComputed, function() return
					context.withScope(new Key("tooltip"), function() return tooltip.build(context)));
				result.add(anchorNode);
				result.add(tooltipNode);
				return result;
			});
			var anchorNode = root.children[0];
			var tooltipNode = root.children[1];
			tooltipNode.layout.style.visible = state.value;
			tooltipNode.onResolved(function(_) {
				if (root.resolved == null || anchorNode.resolved == null || tooltipNode.parent == null ||
					tooltipNode.parent.resolved == null) return;
				var anchorBounds = root.globalBounds();
				var parentBounds = tooltipNode.parent.globalBounds();
				var bounds = tooltipNode.globalBounds();
				var edge = 6.0;
				var maxWidth = Math.max(1, context.viewportWidth - 2 * edge);
				var nextX = Math.max(edge, Math.min(anchorBounds.x + x, context.viewportWidth - edge - bounds.width)) - parentBounds.x;
				var nextY = Math.max(edge, Math.min(anchorBounds.y + y, context.viewportHeight - edge - bounds.height)) - parentBounds.y;
				if (tooltipNode.layout.style.positionX != nextX || tooltipNode.layout.style.positionY != nextY ||
					tooltipNode.layout.style.width.max != maxWidth) {
					tooltipNode.layout.style.positionX = nextX;
					tooltipNode.layout.style.positionY = nextY;
					tooltipNode.layout.style.width = LayoutAxis.fit(0, maxWidth);
					context.requestLayoutFeedback();
				}
			});
			anchorNode.on(UiEventKind.HoverEnter, function(_) {
				state.update(!requirePointerMovement && (showWhen == null || showWhen()));
			});
			if (requirePointerMovement) anchorNode.on(UiEventKind.PointerMove, function(event) {
				var moved = !pointer.known || pointer.x != event.x || pointer.y != event.y;
				pointer.x = event.x; pointer.y = event.y; pointer.known = true;
				if (moved && !state.value && (showWhen == null || showWhen())) state.update(true);
			});
			anchorNode.on(UiEventKind.HoverLeave, function(_) { state.update(false); });
			tooltipNode.on(UiEventKind.HoverEnter, function(_) { state.update(true); });
			tooltipNode.on(UiEventKind.HoverLeave, function(_) { state.update(false); });
			root.hitTestSelf = false;
			return root;
		});
	}
	/** Content width excludes the tooltip's own padding. */
	public static function place(anchorX:Float, anchorHeight:Float, railX:Float, railWidth:Float,
			preferredOffset:Float = 0, ?boxWidth:Float):{x:Float, y:Float, width:Float} {
		var width = Math.max(1, Math.min(300, railWidth - 2 * (EDGE + PADDING)));
		var actualWidth = boxWidth == null ? width + 2 * PADDING : boxWidth;
		var x = Math.max(railX + EDGE - anchorX, Math.min(preferredOffset, railX + railWidth - EDGE - anchorX - actualWidth));
		return {x: x, y: anchorHeight + 4, width: width};
	}
	/** Returns anchor-relative coordinates, preferring right and keeping the box in the viewport. */
	public static function placeRight(anchor:Rect, width:Float, height:Float, viewport:Rect):{x:Float, y:Float, width:Float} {
		var limit = Math.max(1, Math.min(300, viewport.width - 2 * (EDGE + PADDING)));
		var boxWidth = Math.min(width, limit + 2 * PADDING);
		var x = anchor.x + anchor.width + 8;
		if (x + boxWidth > viewport.x + viewport.width - EDGE)
			x = anchor.x - boxWidth - 8;
		x = Math.max(viewport.x + EDGE, Math.min(x, viewport.x + viewport.width - EDGE - boxWidth));
		var y = Math.max(viewport.y + EDGE, Math.min(anchor.y + (anchor.height - height) / 2,
			viewport.y + viewport.height - EDGE - height));
		return {x: x - anchor.x, y: y - anchor.y, width: limit};
	}

	function buildPositioned(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var state = context.resourceState(context.id("visible"), function() return false, function(_) {});
			var delay = context.resourceState(context.id("hover-delay"),
				function() return new TooltipHoverDelay(context.animations, function(value) { state.update(value); }, delaySeconds),
				function(value) value.dispose()).value;
			delay.delaySeconds = delaySeconds;
			var style = new LayoutStyle();
			style.clipToParent = false;
			if (fillAnchor) style.width = LayoutAxis.grow();
			var root = new RenderNode(context.id("layers"), LayoutVisualKind.Box, style);
			root.hitTestSelf = false;
			var header = anchor.build(context);
			if (fillAnchor) header.layout.style.width = LayoutAxis.stretch();
			root.add(header);
			var tipStyle = new LayoutStyle();
			tipStyle.positioning = LayoutPositioning.Absolute;
			tipStyle.positionY = 44;
			tipStyle.zIndex = 10;
			tipStyle.clipToParent = false;
			tipStyle.visible = hoverGroup == null ? state.value : groupVisible;
			tipStyle.padding = new Insets(PADDING, 7, PADDING, 7);
			var tipId = context.id("tooltip");
			var computed = context.resolveStyle(new StyleTarget("tooltip", key.value, key.value, null, ["tooltip"],
				context.interactionStates.get(tipId)), tipStyle);
			var tip = new RenderNode(tipId, LayoutVisualKind.Custom, computed.toLayoutStyle());
			tip.computedStyle = computed;
			tip.setStyleIdentity("tooltip", key.value, key.value, null, ["tooltip"]);
			var label = context.withStyleParent(computed, function() return
				context.withScope(new Key("content"), function() return content.build(context)));
			tip.add(label);
			// The tooltip resolves after its anchor sibling; the parent callback
			// runs before either child has geometry on a freshly built tree.
			tip.onResolved(function(_) {
				if (root.resolved == null || header.resolved == null) return;
				var rail = boundsProvider == null ? new haxeon.ui.Rect(0, 0, context.viewportWidth, context.viewportHeight) : boundsProvider();
				var anchorBounds = root.globalBounds();
				var tipBounds = tip.resolved == null ? null : tip.globalBounds();
				var placement = place(anchorBounds.x, header.globalBounds().height, rail.x, rail.width,
					startAtAnchorMiddle ? anchorBounds.width / 2 : 0, tipBounds == null ? null : tipBounds.width);
				if (this.placement == Above && tipBounds != null) placement.y = -tipBounds.height - 4;
				if (this.placement == Right) {
					var side = placeRight(anchorBounds, tipBounds == null ? 0 : tipBounds.width,
						tipBounds == null ? 0 : tipBounds.height, rail);
					placement.x = side.x;
					placement.y = side.y;
					placement.width = side.width;
				}

				// A window overlay host may have lifted the surface out of the tab.
				if (tip.parent != root && tip.parent != null && tip.parent.resolved != null) {
					var parentBounds = tip.parent.globalBounds();
					placement.x += anchorBounds.x - parentBounds.x;
					placement.y += anchorBounds.y - parentBounds.y;
				}
				if (tip.layout.style.positionX != placement.x || tip.layout.style.positionY != placement.y || label.layout.style.width.max != placement.width) {
					tip.layout.style.positionX = placement.x;
					tip.layout.style.positionY = placement.y;
					label.layout.style.width = LayoutAxis.fit(0, placement.width);
					context.requestLayoutFeedback();
				}
			});
			// The overlay must never extend the tab's hover area into the editor.
			tip.walk(function(node) { node.hitTestSelf = false; });
			root.add(tip);
			header.on(UiEventKind.HoverEnter, function(_) {
				if (hoverGroup != null) hoverGroup.enter(key.value); else delay.start();
			});
			header.on(UiEventKind.HoverLeave, function(_) {
				if (hoverGroup != null) hoverGroup.leave(key.value); else delay.cancel();
			});
			header.on(UiEventKind.PointerDown, function(_) {
				if (hoverGroup != null) hoverGroup.cancel(); else delay.cancel();
			}, "capture");
			return root;
		});
	}
}

private class AnonymousTooltipContent implements View {
	final content:View;
	final style:LayoutStyle;

	public function new(content:View, style:LayoutStyle) {
		this.content = content;
		this.style = style;
	}

	public function build(context:BuildContext):RenderNode {
		var nodeId = context.id("tooltip");
		var computed = context.resolveStyle(
			new StyleTarget("tooltip", "tooltip", "tooltip", null, ["tooltip"],
				context.interactionStates.get(nodeId)), style);
		var node = new RenderNode(nodeId, LayoutVisualKind.Custom, computed.toLayoutStyle());
		node.setStyleIdentity("tooltip", "tooltip", "tooltip", null, ["tooltip"]);
		node.states = context.interactionStates.get(nodeId);
		node.computedStyle = computed;
		var child = context.withStyleParent(computed, function() return
			context.withScope(new Key("content"), function() return content.build(context)));
		node.add(child);
		return node;
	}
}

private class TooltipPointerState {
	public var dismissRevision:Int = -1;
	public var known:Bool = false;
	public var x:Float = 0;
	public var y:Float = 0;
	public function new() {}
}
