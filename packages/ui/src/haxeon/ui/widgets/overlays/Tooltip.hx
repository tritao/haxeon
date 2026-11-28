package haxeon.ui.widgets.overlays;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutAnchor.AnchorSide;
import haxeon.ui.LayoutAnchor.AnchorBounds;
import haxeon.ui.LayoutAnchor.AnchorTarget;
import haxeon.ui.LayoutAnchor;
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
	public final placement:Null<TooltipPlacement>;
	/** Initial hover delay for side-positioned tooltips. */
	public final delaySeconds:Float;

	/** A group shared by neighbouring tooltips, so moving between them shows each at once without the delay again. */
	public final hoverGroup:Null<TooltipHoverGroup>;

	/** Whether its group shows it now; the group sets it. */
	public final groupVisible:Bool;

	/** The area the tooltip must stay within; the viewport when null. */
	public final boundsProvider:Null<Void->Rect>;

	/** Whether a tooltip placed by `placement` starts at the anchor's horizontal middle rather than its left edge. */
	public final startAtAnchorMiddle:Bool;
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
	public final fillAnchor:Bool;
	/** Optional condition checked when the pointer enters the anchor. */
	public final showWhen:Null<Void->Bool>;
	/** Require pointer motion over the anchor, rather than layout-induced hover. */
	public final requirePointerMovement:Bool;
	/** Change this value to dismiss a tooltip when its surrounding content moves. */
	public final dismissRevision:Int;

	/**
	 * A tooltip showing `content` over `anchor`, at (`x`, `y`) from it unless `placement` places it; the rest is given
	 * by name (`placement: Below, delaySeconds: 0.4`).
	 */
	public function new(key:String, anchor:View, content:View, x:Float = 0.0, y:Float = -28.0,
			?placement:TooltipPlacement, delaySeconds:Float = 0.8, ?hoverGroup:TooltipHoverGroup,
			groupVisible:Bool = false, ?boundsProvider:Void->Rect, startAtAnchorMiddle:Bool = false,
			fillAnchor:Bool = false, ?showWhen:Void->Bool, requirePointerMovement:Bool = false,
			dismissRevision:Int = 0) {
		if (anchor == null || content == null) throw "Tooltip requires an anchor and content view";
		this.key = new Key(key);
		this.anchor = anchor;
		this.content = content;
		this.x = x;
		this.y = y;
		this.placement = placement;
		this.delaySeconds = delaySeconds;
		this.hoverGroup = hoverGroup;
		this.groupVisible = groupVisible;
		this.boundsProvider = boundsProvider;
		this.startAtAnchorMiddle = startAtAnchorMiddle;
		this.fillAnchor = fillAnchor;
		this.showWhen = showWhen;
		this.requirePointerMovement = requirePointerMovement;
		this.dismissRevision = dismissRevision;
	}

	public function build(context:BuildContext):ViewRoot {
		if (!hoverEnabled) return context.withScope(key, () -> anchor.build(context));
		if (placement != null) return buildPositioned(context);
		return context.withScope(key, () -> {
			var state:State<Bool> = context.state(context.id("visible"), false);
			var focused = context.state(context.id("focused"), false);
			var pointer = context.resourceState(context.id("pointer-state"),
				() -> new TooltipPointerState(), _ -> {}).value;
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
			anchorModifier.on(UiEventKind.HoverEnter, _ -> {
				focused.update(false);
				pointer.suppressed = false;
				state.update(!requirePointerMovement && (showWhen == null || showWhen()));
			});
			if (requirePointerMovement) anchorModifier.on(UiEventKind.PointerMove, event -> {
				var moved = !pointer.known || pointer.x != event.x || pointer.y != event.y;
				pointer.x = event.x;
				pointer.y = event.y;
				pointer.known = true;
				if (moved && (!state.value || pointer.suppressed) && (showWhen == null || showWhen())) {
					pointer.suppressed = false;
					state.update(true);
				}
			});
			anchorModifier.on(UiEventKind.Focus, event -> {
				pointer.suppressed = false;
				focused.update(!context.interactionStates.peek(event.target).contains(StyleState.Hovered)
					&& (showWhen == null || showWhen()));
			}, UiEventPhase.Capture);
			anchorModifier.on(UiEventKind.Blur, _ -> {
				focused.update(false);
			}, UiEventPhase.Capture);
			anchorModifier.on(UiEventKind.FocusLost, _ -> {
				focused.update(false);
			}, UiEventPhase.Capture);
			anchorModifier.on(UiEventKind.HoverLeave, _ -> {
				state.update(false);
			});
			var root = context.withScope(new Key("layers"), () -> {
				var rootId = context.rootId("stack");
				var result = context.styled(rootId, LayoutVisualKind.Box,
					new StyleIdentity("tooltip-layer", key.rawValue, key.rawValue, null, ["tooltip-layer"]), rootStyle);
				var rootComputed = result.computedStyle;
				var anchorNode = context.withStyleParent(rootComputed,
					() -> context.withScope(new Key("anchor"),
					() -> context.build(anchor, anchorModifier)));
				var tooltipNode = context.withStyleParent(rootComputed,
					() -> context.withScope(new Key("tooltip"), () -> tooltip.build(context)));
				result.add(anchorNode);
				result.add(tooltipNode);
				return result;
			});
			var anchorNode = root.children[0];
			var tooltipNode = root.children[1];
			tooltipNode.layout.style.visible = visible;
			// At its offset from the anchor, kept inside the viewport and no wider than it allows.
			tooltipNode.layout.style.width = LayoutAxis.fit(0, Math.max(1, context.viewportWidth - 2 * EDGE));
			tooltipNode.layout.anchor = new LayoutAnchor(AnchorTarget.Node(root.id.value), margin: EDGE);
			tooltipNode.hitTestBehavior = HitTestBehavior.None;
			root.hitTestSelf = false;
			return root;
		});
	}
	function buildPositioned(context:BuildContext):RenderNode {
		return context.withScope(key, () -> {
			var state = context.resourceState(context.id("visible"), () -> false, _ -> {});
			var focused = context.state(context.id("focused"), false);
			var delay = context.resourceState(context.id("hover-delay"),
				() -> new TooltipHoverDelay(context.animations, value -> {
					state.update(value);
				}, delaySeconds), value -> value.dispose()).value;
			delay.durationSeconds = delaySeconds;
			var style = new LayoutStyle();
			style.clipToParent = false;
			if (fillAnchor) style.width = LayoutAxis.grow();
			var root = context.createNode(context.rootId("layers"), LayoutVisualKind.Box, style);
			root.hitTestSelf = false;
			var headerModifier = new RootModifier();
			if (fillAnchor) headerModifier.width = LayoutAxis.stretch();
			var headerId:Null<WidgetId> = null;
			headerModifier.on(UiEventKind.Focus, _ -> {
				focused.update((headerId == null
					|| !context.interactionStates.peek(headerId).contains(StyleState.Hovered))
					&& (showWhen == null || showWhen()));
			});
			headerModifier.on(UiEventKind.Blur, _ -> {
				focused.update(false);
			});
			headerModifier.on(UiEventKind.FocusLost, _ -> {
				focused.update(false);
			});
			headerModifier.on(UiEventKind.HoverEnter, _ -> {
				focused.update(false);
				if (showWhen == null || showWhen()) {
					if (hoverGroup != null) hoverGroup.enter(key.rawValue);
					else delay.start();
				}
			});
			headerModifier.on(UiEventKind.HoverLeave, _ -> {
				if (hoverGroup != null) hoverGroup.leave(key.rawValue);
				else delay.cancel();
			});
			headerModifier.on(UiEventKind.PointerDown, _ -> {
				if (hoverGroup != null) hoverGroup.cancel();
				else delay.cancel();
			}, UiEventPhase.Capture);
			var header = context.build(anchor, headerModifier);
			headerId = header.id;
			root.add(header);
			var tipStyle = new LayoutStyle();
			tipStyle.positioning = LayoutPositioning.Absolute;
			tipStyle.overlay = true;
			tipStyle.clipToParent = false;
			tipStyle.visible = focused.value || (hoverGroup == null ? state.value : groupVisible);
			tipStyle.padding = new Insets(PADDING, 7, PADDING, 7);
			var tipId = context.id("tooltip");
			var identity = new StyleIdentity("tooltip", key.rawValue, key.rawValue, null, ["tooltip"]);
			var computed = context.resolveStyled(tipId, identity, tipStyle);
			var tip = context.createNode(tipId, LayoutVisualKind.Custom, computed.toLayoutStyle());
			context.applyStyled(tip, identity, computed);
			// A hidden tooltip builds no content: showing it rebuilds. The tooltip owns the box around its content, at most 300
			// wide and as the rail allows; the content's own root is the content view's.
			var rail = boundsProvider == null ? null : boundsProvider();
			var railWidth = rail == null ? context.viewportWidth : rail.width;
			if (tipStyle.visible) {
				var boxStyle = new LayoutStyle();
				boxStyle.width = LayoutAxis.fit(0, Math.max(1, Math.min(300, railWidth - 2 * (EDGE + PADDING))));
				var box = context.createNode(context.rootId("tooltip-content"), LayoutVisualKind.Box, boxStyle);
				box.hitTestSelf = false;
				box.add(context.withStyleParent(computed,
					() -> context.withScope(new Key("content"), () -> content.build(context))));
				tip.add(box);
			}
			// Below its header (from the header's middle with startAtAnchorMiddle), above it, or beside it centred and on
			// the other side when it does not fit; kept inside the rail.
			var beside = placement == Right;
			tip.layout.anchor = new LayoutAnchor(AnchorTarget.Node(header.id.value),
				side: beside ? AnchorSide.After : placement == Above ? AnchorSide.Above : AnchorSide.Below,
				gap: beside ? 8.0 : 4.0, align: beside || startAtAnchorMiddle ? 0.5 : 0.0, boxAlign: beside ? 0.5 : 0.0,
				flip: beside, within: rail == null ? AnchorBounds.Viewport : AnchorBounds.Area(rail), margin: EDGE);
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
		var node = context.styled(nodeId, LayoutVisualKind.Custom,
			new StyleIdentity("tooltip", "tooltip", "tooltip", null, ["tooltip"]), style);
		var computed = node.computedStyle;
		if (showContent) {
			var child = context.withStyleParent(computed,
				() -> context.withScope(new Key("content"), () -> content.build(context)));
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
			() -> new Array<{
				tip:RenderNode,
				anchor:RenderNode
			}>()).value;
		// Retained anchors must recover their tooltip before being reused.
		for (entry in lifted) entry.anchor.add(entry.tip.detach());
		lifted.resize(0);
		// Hosting lifts nodes out of its content's subtree, which only an overlay host may do.
		var root = content.build(context).node();
		var tooltips:Array<RenderNode> = [];
		root.walk(node -> {
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
		context.onPatched = patched -> {
			var overlay = context.currentRoot(root);
			var made:Array<RenderNode> = [];
			patched.walk(node -> {
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
