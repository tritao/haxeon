package haxeon.ui.widgets.overlays;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.style.StyleState;

/** Informational tooltip layered above its anchor. Content never participates in pointer hit testing. */
class Tooltip implements View {
	/** Hosts without a hovering pointer (touch) turn this off; a tooltip then draws only its anchor. */
	public static var hoverEnabled:Bool = true;
	/** Preferred side. Null preserves explicit x/y positioning. */
	public var placement:Null<TooltipPlacement> = null;
	/** Initial hover delay for side-positioned tooltips. */
	public var delaySeconds:Float = 0.8;

	/** A group shared by neighbouring tooltips, so moving between them shows each at once without the delay again. */
	public var hoverGroup:Null<TooltipHoverGroup> = null;

	/** Whether its group shows it now; the group sets it. */
	public var groupVisible:Bool = false;

	/** The area the tooltip must stay within; the viewport when null. */
	public var boundsProvider:Null<Void->Rect> = null;

	/** Whether a tooltip placed by `placement` starts at the anchor's horizontal middle rather than its left edge. */
	public var startAtAnchorMiddle:Bool = false;
	static inline final PADDING = 10.0;
	static inline final EDGE = 6.0;
	/** Private resolver inputs; resolved nodes own their own mutable styles. */
	static final DefaultHiddenStyle:LayoutStyle = inlineTooltipStyle(0.0, -28.0, false);
	static final DefaultVisibleStyle:LayoutStyle = inlineTooltipStyle(0.0, -28.0, true);
	static final FitRootStyle:LayoutStyle = inlineRootStyle(false);
	static final FillRootStyle:LayoutStyle = inlineRootStyle(true);

	static function inlineTooltipStyle(x:Float, y:Float, visible:Bool):LayoutStyle {
		var result = new LayoutStyle();
		result.positioning = LayoutPositioning.Absolute;
		result.overlay = true;
		result.positionX = x;
		result.positionY = y;
		result.clipToParent = false;
		result.visible = visible;
		return result;
	}

	static function inlineRootStyle(fill:Bool):LayoutStyle {
		var result = new LayoutStyle();
		result.width = fill ? LayoutAxis.grow() : LayoutAxis.fit();
		result.height = LayoutAxis.fit();
		result.clipToParent = false;
		return result;
	}

	final key:Key;
	final anchor:View;
	final content:View;

	/** Its left edge, from the anchor's, when `placement` is null. */
	public final x:Float;

	/** Its top edge, from the anchor's, when `placement` is null. */
	public final y:Float;
	/** Fill the available row width when the anchor needs to clip long text. */
	public var fillAnchor:Bool = false;
	/** Optional condition checked when the pointer enters the anchor. */
	public var showWhen:Null<Void->Bool> = null;
	/** Require pointer motion over the anchor, rather than layout-induced hover. */
	public var requirePointerMovement:Bool = false;
	/** Change this value to dismiss a tooltip when its surrounding content moves. */
	public var dismissRevision:Int = 0;

	/** A tooltip showing `content` over `anchor`, at (`x`, `y`) from it unless `placement` places it. */
	public function new(key:String, anchor:View, content:View, x:Float = 0.0, y:Float = -28.0) {
		if (anchor == null || content == null) throw "Tooltip requires an anchor and content view";
		this.key = new Key(key);
		this.anchor = anchor;
		this.content = content;
		this.x = x;
		this.y = y;
	}

	public function build(context:BuildContext):ViewRoot {
		if (!hoverEnabled) return context.withScope(key, function() return anchor.build(context));
		if (placement != null) return buildPositioned(context);
		return context.withScope(key, function() {
			var state:State<Bool> = context.state(context.id("visible"), false);
			var focused = context.state(context.id("focused"), false);
			var pointer = context.resourceState(context.id("pointer-state"),
				function() return new TooltipPointerState(), function(_) {}).value;
			if (pointer.dismissRevision != dismissRevision) {
				pointer.dismissRevision = dismissRevision;
				pointer.suppressed = true;
			}
			var visible = (state.value || focused.value) && !pointer.suppressed;
			// Preserve signed zero for explicit coordinates rather than treating -0 as the default +0.
			var defaultPosition = x == 0.0 && 1.0 / x > 0.0 && y == -28.0;
			var tooltipStyle = defaultPosition
				? (visible ? DefaultVisibleStyle : DefaultHiddenStyle) : inlineTooltipStyle(x,
				y,
				visible);
			var tooltip = new AnonymousTooltipContent(content, tooltipStyle, visible);
			var rootStyle = fillAnchor ? FillRootStyle : FitRootStyle;
			var anchorModifier = new RootModifier();
			anchorModifier.on(UiEventKind.HoverEnter, function(_) {
				focused.update(false);
				pointer.suppressed = false;
				state.update(!requirePointerMovement && (showWhen == null || showWhen()));
			});
			if (requirePointerMovement) anchorModifier.on(UiEventKind.PointerMove, function(event) {
				var moved = !pointer.known || pointer.x != event.x || pointer.y != event.y;
				pointer.x = event.x;
				pointer.y = event.y;
				pointer.known = true;
				if (moved && (!state.value || pointer.suppressed) && (showWhen == null || showWhen())) {
					pointer.suppressed = false;
					state.update(true);
				}
			});
			anchorModifier.on(UiEventKind.Focus, function(event) {
				pointer.suppressed = false;
				focused.update(!context.interactionStates.peek(event.target).contains(StyleState.Hovered)
					&& (showWhen == null || showWhen()));
			}, UiEventPhase.Capture);
			anchorModifier.on(UiEventKind.Blur, function(_) {
				focused.update(false);
			}, UiEventPhase.Capture);
			anchorModifier.on(UiEventKind.FocusLost, function(_) {
				focused.update(false);
			}, UiEventPhase.Capture);
			anchorModifier.on(UiEventKind.HoverLeave, function(_) {
				state.update(false);
			});
			var root = context.withScope(new Key("layers"), function() {
				var rootId = context.rootId("stack");
				var rootComputed = context.resolveStyle(context.styleTarget(rootId, "tooltip-layer",
					key.rawValue,
					key.rawValue,
					null,
					["tooltip-layer"]),
					rootStyle);
				var result = context.createNode(rootId, LayoutVisualKind.Box, rootComputed.toLayoutStyle());
				result.setStyleIdentity("tooltip-layer", key.rawValue, key.rawValue, null, ["tooltip-layer"]);
				result.states = context.interactionStates.peek(rootId);
				result.computedStyle = rootComputed;
				var anchorNode = context.withStyleParent(rootComputed,
					function() return context.withScope(new Key("anchor"),
					function() return context.build(anchor, anchorModifier)));
				var tooltipNode = context.withStyleParent(rootComputed,
					function() return context.withScope(new Key("tooltip"), function() return tooltip.build(context)));
				result.add(anchorNode);
				result.add(tooltipNode);
				return result;
			});
			var anchorNode = root.children[0];
			var tooltipNode = root.children[1];
			tooltipNode.layout.style.visible = visible;
			tooltipNode.onResolved(function(_) {
				// Resolved callbacks run on every frame; a hidden tooltip needs no placement, and showing it rebuilds.
				if (!tooltipNode.layout.style.visible) return;
				if (root.resolved == null
					|| anchorNode.resolved == null || tooltipNode.parent == null
					|| tooltipNode.parent.resolved == null) return;
				var anchorBounds = root.globalBounds();
				var parentBounds = tooltipNode.parent.globalBounds();
				var bounds = tooltipNode.globalBounds();
				var edge = 6.0;
				var maxWidth = Math.max(1, context.viewportWidth - 2 * edge);
				var nextX = Math.max(edge,
					Math.min(anchorBounds.x + x, context.viewportWidth - edge - bounds.width)) - parentBounds.x;
				var nextY = Math.max(edge,
					Math.min(anchorBounds.y + y, context.viewportHeight - edge - bounds.height)) - parentBounds.y;
				if (tooltipNode.layout.style.positionX != nextX
					|| tooltipNode.layout.style.positionY != nextY || tooltipNode.layout.style.width.max != maxWidth) {
					context.willEditRetained(tooltipNode);
					tooltipNode.layout.style.positionX = nextX;
					tooltipNode.layout.style.positionY = nextY;
					tooltipNode.layout.style.width = LayoutAxis.fit(0, maxWidth);
					context.requestLayoutFeedback();
				}
			});
			tooltipNode.hitTestBehavior = HitTestBehavior.None;
			root.hitTestSelf = false;
			return root;
		});
	}
	/** Content width excludes the tooltip's own padding. */
	public static function place(anchorX:Float,
			anchorHeight:Float,
			railX:Float,
			railWidth:Float,
			preferredOffset:Float = 0,
			?boxWidth:Float):{
				x:Float,
				y:Float,
				width:Float
			} {
		var width = Math.max(1, Math.min(300, railWidth - 2 * (EDGE + PADDING)));
		var actualWidth = boxWidth == null ? width + 2 * PADDING : boxWidth;
		var x = Math.max(railX + EDGE - anchorX,
			Math.min(preferredOffset, railX + railWidth - EDGE - anchorX - actualWidth));
		return {x: x, y: anchorHeight + 4, width: width};
	}
	/** Returns anchor-relative coordinates, preferring right and keeping the box in the viewport. */
	public static function placeRight(anchor:Rect, width:Float, height:Float, viewport:Rect):{
		x:Float,
		y:Float,
		width:Float
	} {
		var limit = Math.max(1, Math.min(300, viewport.width - 2 * (EDGE + PADDING)));
		var boxWidth = Math.min(width, limit + 2 * PADDING);
		var x = anchor.x + anchor.width + 8;
		if (x + boxWidth > viewport.x + viewport.width - EDGE) x = anchor.x - boxWidth - 8;
		x = Math.max(viewport.x + EDGE, Math.min(x, viewport.x + viewport.width - EDGE - boxWidth));
		var y = Math.max(viewport.y + EDGE,
			Math.min(anchor.y + (anchor.height - height) / 2, viewport.y + viewport.height - EDGE - height));
		return {x: x - anchor.x, y: y - anchor.y, width: limit};
	}

	function buildPositioned(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var state = context.resourceState(context.id("visible"), function() return false, function(_) {});
			var focused = context.state(context.id("focused"), false);
			var delay = context.resourceState(context.id("hover-delay"),
				function() return new TooltipHoverDelay(context.animations, function(value) {
					state.update(value);
				}, delaySeconds), function(value) value.dispose()).value;
			delay.durationSeconds = delaySeconds;
			var style = new LayoutStyle();
			style.clipToParent = false;
			if (fillAnchor) style.width = LayoutAxis.grow();
			var root = context.createNode(context.rootId("layers"), LayoutVisualKind.Box, style);
			root.hitTestSelf = false;
			var headerModifier = new RootModifier();
			if (fillAnchor) headerModifier.width = LayoutAxis.stretch();
			var headerId:Null<WidgetId> = null;
			headerModifier.on(UiEventKind.Focus, function(_) {
				focused.update((headerId == null
					|| !context.interactionStates.peek(headerId).contains(StyleState.Hovered))
					&& (showWhen == null || showWhen()));
			});
			headerModifier.on(UiEventKind.Blur, function(_) {
				focused.update(false);
			});
			headerModifier.on(UiEventKind.FocusLost, function(_) {
				focused.update(false);
			});
			headerModifier.on(UiEventKind.HoverEnter, function(_) {
				focused.update(false);
				if (showWhen == null || showWhen()) {
					if (hoverGroup != null) hoverGroup.enter(key.rawValue);
					else delay.start();
				}
			});
			headerModifier.on(UiEventKind.HoverLeave, function(_) {
				if (hoverGroup != null) hoverGroup.leave(key.rawValue);
				else delay.cancel();
			});
			headerModifier.on(UiEventKind.PointerDown, function(_) {
				if (hoverGroup != null) hoverGroup.cancel();
				else delay.cancel();
			}, UiEventPhase.Capture);
			var header = context.build(anchor, headerModifier);
			headerId = header.id;
			root.add(header);
			var tipStyle = new LayoutStyle();
			tipStyle.positioning = LayoutPositioning.Absolute;
			tipStyle.overlay = true;
			tipStyle.positionY = 44;
			tipStyle.clipToParent = false;
			tipStyle.visible = focused.value || (hoverGroup == null ? state.value : groupVisible);
			tipStyle.padding = new Insets(PADDING, 7, PADDING, 7);
			var tipId = context.id("tooltip");
			var computed = context.resolveStyle(context.styleTarget(tipId, "tooltip",
				key.rawValue,
				key.rawValue,
				null,
				["tooltip"]),
				tipStyle);
			var tip = context.createNode(tipId, LayoutVisualKind.Custom, computed.toLayoutStyle());
			tip.computedStyle = computed;
			tip.setStyleIdentity("tooltip", key.rawValue, key.rawValue, null, ["tooltip"]);
			// A hidden tooltip builds no content: showing it rebuilds, and the layout feedback below positions it that frame.
			// The tooltip owns the box around its content, whose width placement limits; the content's own root is the
			// content view's.
			var label:Null<RenderNode> = null;
			if (tipStyle.visible) {
				var box = context.createNode(context.rootId("tooltip-content"), LayoutVisualKind.Box,
					new LayoutStyle());
				box.hitTestSelf = false;
				box.add(context.withStyleParent(computed,
					function() return context.withScope(new Key("content"), function() return content.build(context))));
				tip.add(box);
				label = box;
			}
			// The tooltip resolves after its anchor sibling; the parent callback
			// runs before either child has geometry on a freshly built tree.
			tip.onResolved(function(_) {
				// Resolved callbacks run on every frame; a hidden tooltip needs no placement, and showing it rebuilds.
				if (!tip.layout.style.visible) return;
				if (root.resolved == null || header.resolved == null) return;
				var rail = boundsProvider == null ? new haxeon.ui.Rect(0,
					0, context.viewportWidth, context.viewportHeight) : boundsProvider();
				var anchorBounds = root.globalBounds();
				var tipBounds = tip.resolved == null ? null : tip.globalBounds();
				var placement = place(anchorBounds.x,
					header.globalBounds().height,
					rail.x,
					rail.width,
					startAtAnchorMiddle ? anchorBounds.width / 2 : 0,
					tipBounds == null ? null : tipBounds.width);
				if (this.placement == Above && tipBounds != null) placement.y = -tipBounds.height - 4;
				if (this.placement == Right) {
					var side = placeRight(anchorBounds,
						tipBounds == null ? 0 : tipBounds.width,
						tipBounds == null ? 0 : tipBounds.height,
						rail);
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
				var shownLabel = label;
				var labelWidth = shownLabel == null ? placement.width : shownLabel.layout.style.width.max;
				if (tip.layout.style.positionX != placement.x
					|| tip.layout.style.positionY != placement.y || labelWidth != placement.width) {
					context.willEditRetained(tip);
					if (shownLabel != null) context.willEditRetained(shownLabel);
					tip.layout.style.positionX = placement.x;
					tip.layout.style.positionY = placement.y;
					if (shownLabel != null) shownLabel.layout.style.width = LayoutAxis.fit(0, placement.width);
					context.requestLayoutFeedback();
				}
			});
			// The overlay must never extend the tab's hover area into the editor.
			tip.hitTestBehavior = HitTestBehavior.None;
			root.add(tip);
			return root;
		});
	}
}

private class AnonymousTooltipContent implements View {
	final content:View;
	final style:LayoutStyle;
	/** A hidden tooltip keeps its node, so it can show and be positioned, but builds no content until it is shown. */
	final showContent:Bool;

	public function new(content:View, style:LayoutStyle, showContent:Bool) {
		this.content = content;
		this.style = style;
		this.showContent = showContent;
	}

	public function build(context:BuildContext):ViewRoot {
		var nodeId = context.rootId("tooltip");
		var computed = context.resolveStyle(context.styleTarget(nodeId, "tooltip", "tooltip", "tooltip", null,
			["tooltip"]),
			style);
		var node = context.createNode(nodeId, LayoutVisualKind.Custom, computed.toLayoutStyle());
		node.setStyleIdentity("tooltip", "tooltip", "tooltip", null, ["tooltip"]);
		node.states = context.interactionStates.peek(nodeId);
		node.computedStyle = computed;
		if (showContent) {
			var child = context.withStyleParent(computed,
				function() return context.withScope(new Key("content"), function() return content.build(context)));
			node.add(child);
		}
		return node;
	}
}

private class TooltipPointerState {
	public var dismissRevision:Int = -1;
	public var suppressed:Bool = false;
	public var known:Bool = false;
	public var x:Float = 0;
	public var y:Float = 0;
	public function new() {}
}

/** Preferred side of a tooltip, independent of hover timing. */
enum TooltipPlacement {
	/** Under the anchor. */
	Below;
	/** Over the anchor. */
	Above;
	/** To the anchor's right. */
	Right;
}

/** The rest before a tooltip shows: started when the pointer comes over its anchor, cancelled when it leaves. */
class TooltipHoverDelay implements DelayedAnimation implements Disposable {
	final scheduler:AnimationScheduler;
	final changed:Bool->Void;
	var remaining:Float = 0;
	var pending:Bool = false;
	var disposed:Bool = false;

	/** How long the pointer must rest before the tooltip shows. */
	public var durationSeconds:Float;

	/** A delay that calls `changed` with true once `delaySeconds` pass after `start`, and with false when cancelled. */
	public function new(scheduler:AnimationScheduler, changed:Bool->Void, delaySeconds:Float = 0.8) {
		this.durationSeconds = delaySeconds;
		this.scheduler = scheduler;
		this.changed = changed;
	}

	/** Starts the delay again. */
	public function start():Void {
		if (disposed)
			return;
		pending = true;
		remaining = durationSeconds;
		changed(false);
		scheduler.track(this);
	}

	/** Stops the delay and hides the tooltip. */
	public function cancel():Void {
		scheduler.remove(this);
		pending = false;
		remaining = 0;
		changed(false);
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!pending || disposed)
			return false;
		remaining -= deltaSeconds;
		if (remaining > 0)
			return true;
		pending = false;
		changed(true);
		return false;
	}

	public function delaySeconds():Float
		return pending ? Math.max(0, remaining) : 0;

	public function dispose():Void {
		scheduler.remove(this);
		disposed = true;
		pending = false;
	}
}

/** Shared hover timing lets neighboring labels switch without restarting the delay. */
class TooltipHoverGroup implements Animation implements Disposable {
	final scheduler:AnimationScheduler;
	final changed:Null<String>->Void;
	var hovered:Null<String>;
	var visible:Null<String>;
	var remaining:Float = 0;
	/** How long the pointer must rest before the group's first tooltip shows. */
	public var delaySeconds:Float;

	/** A group calling `changed` with the key of the tooltip to show, or null for none. */
	public function new(scheduler:AnimationScheduler, changed:Null<String>->Void, delaySeconds:Float) {
		this.scheduler = scheduler;
		this.changed = changed;
		this.delaySeconds = delaySeconds;
	}

	/**
	 * The pointer came over the tooltip `key`: shows it after the delay, or at once when another of the group is
	 * showing.
	 */
	public function enter(key:String):Void {
		hovered = key;
		if (visible != null || delaySeconds <= 0) {
			scheduler.remove(this);
			show(key);
		} else {
			remaining = delaySeconds;
			scheduler.track(this);
		}
	}

	/** The pointer left the tooltip `key`. */
	public function leave(key:String):Void {
		if (hovered != key) return;
		hovered = null;
		if (visible == null) scheduler.remove(this);
		else {
			remaining = 0.4;
			scheduler.track(this);
		}
	}

	/** Hides the group's tooltips and resets the delay. */
	public function cancel():Void {
		hovered = null;
		scheduler.remove(this);
		show(null);
	}

	function show(key:Null<String>):Void {
		visible = key;
		changed(key);
	}

	public function advance(deltaSeconds:Float):Bool {
		remaining -= deltaSeconds;
		if (remaining > 0) return true;
		show(hovered);
		return false;
	}

	public function dispose():Void scheduler.remove(this);
}

/** Lift tooltip surfaces out of clipped stacking contexts before layout. */
class TooltipOverlayHost implements View {
	final content:View;
	/** Hosts `content`, lifting its tooltips above it so a clipped container does not cut them off. */
	public function new(content:View) this.content = content;
	public function build(context:BuildContext):ViewRoot {
		var lifted = context.lazyState(context.id("lifted-tooltips"),
			function() return new Array<{
				tip:RenderNode,
				anchor:RenderNode
			}>()).value;
		// Retained anchors must recover their tooltip before being reused.
		for (entry in lifted) entry.anchor.add(entry.tip.detach());
		lifted.resize(0);
		// Hosting lifts nodes out of its content's subtree, which only an overlay host may do.
		var root = content.build(context).node();
		var tooltips:Array<RenderNode> = [];
		root.walk(function(node) {
			if (node.styleType == "tooltip") tooltips.push(node);
		});
		for (tip in tooltips) {
			lifted.push({tip: tip, anchor: tip.parent});
			root.add(tip.detach());
		}
		// A component that runs again alone rebuilds without the view, so what it made has tooltips still in their anchors
		// while the ones lifted by the build before stay in the overlay: both would carry one ID. Lift what it made in the place
		// of the tooltip it replaces. When the content is that component, its new root took the overlay's place (and the
		// lifted tooltips, which its boundary keeps as the caller's).
		context.onPatched = function(patched) {
			var overlay = context.currentRoot(root);
			var made:Array<RenderNode> = [];
			patched.walk(function(node) {
				if (node.styleType == "tooltip" && node.parent != overlay) made.push(node);
			});
			for (tip in made) {
				var anchor = tip.parent;
				if (anchor == null) continue;
				var position = -1;
				for (index in 0...lifted.length) if (lifted[index].tip.id.value == tip.id.value) {
					position = index;
					break;
				}
				var entry = {tip: tip, anchor: anchor};
				if (position < 0) {
					lifted.push(entry);
					overlay.add(tip.detach());
					continue;
				}
				var previous = lifted[position].tip;
				lifted[position] = entry;
				tip.detach();
				if (previous.parent == overlay) previous.replaceWith(tip);
				else overlay.add(tip);
			}
		};
		return root;
	}
}
