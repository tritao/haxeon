package haxeon.ui.widgets.scroll;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutPlacer;
import haxeon.ui.LayoutStyle;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.animation.AnimationScheduler;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.gestures.GestureRecognizer;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleState;

/** Clipped Haxe scroll container translated from its persistent controller offset. */
class ScrollView implements View {
	static inline var ScrollbarHitWidth:Float = 12.0;
	static inline var ScrollbarInset:Float = 2.0;
	/** Distance a touch must travel before it becomes a scroll rather than a tap. */
	static inline var TouchSlop:Float = 8.0;
	final key:Key;
	final child:View;
	final axis:ScrollAxis;
	final suppliedController:Bool;

	/** The viewport's box, which clips the content. */
	public final style:LayoutStyle;

	/** The scroll position, which a caller can share to read or move it. */
	public var controller(default, null):ScrollController;

	/** Called with each scroll event the view handles. */
	public final onScroll:UiEvent->Void;
	/** Shows an interactive overlay scrollbar when vertical content overflows. */
	public final showScrollbar:Bool;

	/** The scroll area's accessible name. */
	public final label:Null<String>;
	/**
	 * Set when the content builds from the scroll offset, as virtualized rows do: scrolling then rebuilds the view. Otherwise
	 * the content is moved in place and nothing is rebuilt.
	 */
	public final contentFollowsOffset:Bool;
	/** Expand content to fill a short viewport while retaining intrinsic scroll overflow. */
	public final fillViewport:Bool;
	/** Optional intrinsic content dimensions for clipped or virtualized document widgets. */
	public final contentExtentProvider:Null<(Float, Float) -> {width:Float, height:Float}>;
	/** Null inherits the application environment policy. */
	public final scrollbarVisibility:Null<ScrollbarVisibility>;
	/** Optional non-scrolling ancestor with the same vertical extent. */
	public final scrollbarOverlayHost:Null<RenderNode>;

	/** A viewport scrolling `child` along `axis`. Throws without a child or with an unknown axis. */
	public function new(key:String,
			child:View,
			?style:LayoutStyle,
			axis:ScrollAxis = ScrollAxis.Vertical,
			?controller:ScrollController,
			?onScroll:UiEvent->Void,
			showScrollbar:Bool = true,
			?label:String,
			contentFollowsOffset:Bool = false,
			fillViewport:Bool = false,
			?contentExtentProvider:(Float, Float) -> {width:Float, height:Float},
			?scrollbarVisibility:ScrollbarVisibility,
			?scrollbarOverlayHost:RenderNode) {
		if (child == null || (axis != ScrollAxis.Vertical && axis != ScrollAxis.Horizontal
			&& axis != ScrollAxis.Both)) throw "ScrollView requires a child and a supported axis";
		this.key = new Key(key);
		this.child = child;
		this.axis = axis;
		this.style = style == null ? new LayoutStyle() : style.copy();
		suppliedController = controller != null;
		this.controller = controller == null ? new ScrollController() : controller;
		this.onScroll = onScroll;
		this.showScrollbar = showScrollbar;
		this.label = label;
		this.contentFollowsOffset = contentFollowsOffset;
		this.fillViewport = fillViewport;
		this.contentExtentProvider = contentExtentProvider;
		this.scrollbarVisibility = scrollbarVisibility;
		this.scrollbarOverlayHost = scrollbarOverlayHost;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, function() {
			var viewportStyle = style.copy();
			var id = context.rootId("scroll");
			var viewport = context.styled(id, LayoutVisualKind.Box,
				new StyleIdentity("scroll-view", key.rawValue, key.rawValue, null, ["scroll-view"]), viewportStyle);
			var computed = viewport.computedStyle;
			// The scrollbars follow hover through the listeners below; a build only starts them from the current state.
			var hovered = context.interactionStates.peek(id).contains(StyleState.Hovered);
			viewport.focusable = true;
			var semantics = new Semantics(AccessibilityRole.ScrollArea, label);
			semantics.actions = AccessibilityAction.ScrollForward | AccessibilityAction.ScrollBackward;
			viewport.semantics = semantics;
			viewport.layout.style.clipHorizontal = viewport.layout.style.clipHorizontal
				|| axis == ScrollAxis.Horizontal || axis == ScrollAxis.Both;
			viewport.layout.style.clipVertical = viewport.layout.style.clipVertical
				|| axis == ScrollAxis.Vertical || axis == ScrollAxis.Both;
			if (!suppliedController) {
				var stored:State<ScrollController> = context.resourceState(viewport.id,
					function() return controller, function(_) {});
				controller = stored.value;
			}
			// Virtual content is built by the surrounding owner before ScrollView builds. Subscribe that owner to
			// offset changes, so translating retained rows cannot leave an obsolete materialization window on screen.
			var contentRevision:Null<State<Int>> = contentFollowsOffset ? context.state(context.id("content-revision"),
				0) : null;
			if (contentRevision != null) contentRevision.value;
			var builtOffsetX = controller.offsetX, builtOffsetY = controller.offsetY;
			var builtViewportWidth = controller.viewportWidth, builtViewportHeight = controller.viewportHeight;
			// Fully materialized content only moves in place; it reads no scroll-dependent signal.
			var binding = context.resourceState(context.id("controller-binding"),
				function() return new ScrollBinding(),
				function(value) value.dispose());
			var visibility = context.resourceState(context.id("scrollbar-visibility"),
				function() return new ScrollbarVisibilityController(),
				function(value) value.dispose());
			// The scrollbar, when there is one, attaches its own callback, which edits its nodes in place (see addScrollbar).
			visibility.value.attach(context.animations, function() {});
			visibility.value.bindSource(controller);
			var policy:ScrollbarVisibility = scrollbarVisibility == null
				? context.environment.scrollbarVisibility : scrollbarVisibility;
			visibility.value.configure(showScrollbar ? policy : ScrollbarVisibility.Hidden,
				context.environment.reducedMotion);

			visibility.value.setViewportHovered(hovered);
			viewport.onTargetBubble(UiEventKind.HoverEnter, function(event) {
				if (event.target.equals(viewport.id)) visibility.value.setViewportHovered(true);
			});
			viewport.onTargetBubble(UiEventKind.HoverLeave, function(event) {
				if (event.target.equals(viewport.id)) visibility.value.setViewportHovered(false);
			});

			var contentStyle = new LayoutStyle();
			// Explicit document extents must not become the viewport's minimum layout size.
			// Keep that content outside parent flow; its provider owns the scroll range.
			if (contentExtentProvider != null) contentStyle.positioning = LayoutPositioning.Absolute;
			contentStyle.width = axis
				== ScrollAxis.Vertical ? LayoutAxis.stretch() : fillViewport ? LayoutAxis.grow() : LayoutAxis.fit();
			contentStyle.height = axis == ScrollAxis.Horizontal || fillViewport ? LayoutAxis.grow() : LayoutAxis.fit();
			var translatedContent = context.createNode(context.rootId("scroll-content"), LayoutVisualKind.Box,
				contentStyle);
			// Layout settles the offset against the viewport and the content, and moves the content by it.
			translatedContent.layout.scroll = new ContentScroll(controller, contentExtentProvider);
			var content = context.withStyleParent(computed, function() {
				return context.withScope(new Key("content"), function() return child.build(context));
			});
			translatedContent.add(content);
			var horizontalVisibility = context.resourceState(context.id("horizontal-scrollbar-visibility"),
				function() return new ScrollbarVisibilityController(),
				function(value) value.dispose());
			horizontalVisibility.value.bindSource(controller);
			horizontalVisibility.value.configure(showScrollbar ? policy : ScrollbarVisibility.Hidden,
				context.environment.reducedMotion);
			horizontalVisibility.value.setViewportHovered(hovered);
			viewport.onTargetBubble(UiEventKind.HoverEnter, function(event) {
				if (event.target.equals(viewport.id)) horizontalVisibility.value.setViewportHovered(true);
			});
			viewport.onTargetBubble(UiEventKind.HoverLeave, function(event) {
				if (event.target.equals(viewport.id)) horizontalVisibility.value.setViewportHovered(false);
			});
			viewport.add(translatedContent);
			var overlayHost = scrollbarOverlayHost == null ? viewport : scrollbarOverlayHost;
			var scrollbar = showScrollbar
				&& policy != ScrollbarVisibility.Hidden && axis != ScrollAxis.Horizontal ? addScrollbar(context,
				overlayHost,
				visibility.value,
				true) : null;

			var horizontal = showScrollbar
				&& policy != ScrollbarVisibility.Hidden && axis != ScrollAxis.Vertical ? addScrollbar(context,
				overlayHost,
				horizontalVisibility.value,
				false) : null;
			var lastOffsetX = controller.offsetX, lastOffsetY = controller.offsetY;
			binding.value.attach(controller, context.animations, function(_) {
				// A scroll from input or an animation moves the window: tell the owner. An offset set while a view is
				// building (an owner keeping its anchor or a selection in view) is already in the window being built,
				// and writing state there is forbidden; the resolved-geometry check below covers any later change.
				if (contentRevision != null && !haxeon.reactive.ReactiveRuntime.isTracking()
					&& (lastOffsetX != controller.offsetX || lastOffsetY != controller.offsetY)) {
					lastOffsetX = controller.offsetX;
					lastOffsetY = controller.offsetY;
					contentRevision.update(contentRevision.value + 1);
				}
				// Layout moves the content, and places the scrollbars, from the new offset.
				context.requestLayout();
				visibility.value.reveal();
				horizontalVisibility.value.reveal();
			});

			translatedContent.onResolved(function(geometry) {
				// Layout has settled the controller's metrics and offset (ContentScroll).
				var materializedViewportChanged = (axis != ScrollAxis.Horizontal
					&& builtViewportHeight != controller.viewportHeight)
					|| (axis != ScrollAxis.Vertical && builtViewportWidth != controller.viewportWidth);
				var materializedOffsetChanged = (axis != ScrollAxis.Horizontal
					&& builtOffsetY != controller.offsetY)
					|| (axis != ScrollAxis.Vertical && builtOffsetX != controller.offsetX);
				if (contentRevision != null
					&& context.buildFeedbackPass == 0 && (materializedOffsetChanged || materializedViewportChanged)) {
					// Layout may resize the viewport or clamp its offset: rebuild the window once before painting this
					// frame when an axis used by the virtual window changes. Content whose size depends on its own window
					// (a viewport that fits its rows) can disagree
					// again after that rebuild; it is settled on the next frame rather than by unbounded rebuilds.
					contentRevision.update(contentRevision.value + 1);
					context.requestBuildFeedbackBeforeLayout();
				}
				visibility.value.setAvailable(scrollbar != null && controller.maxScrollY > 0
					&& controller.viewportHeight > 0);
				horizontalVisibility.value.setAvailable(horizontal != null
					&& controller.maxScrollX > 0 && controller.viewportWidth > 0);
				if (scrollbar != null) syncScrollbar(scrollbar, true);
				if (horizontal != null) syncScrollbar(horizontal, false);
			});
			viewport.on(UiEventKind.Scroll, function(event) {
				if (onScroll != null) onScroll(event);
				if (event.defaultPrevented) return;
				var dx = axis == ScrollAxis.Horizontal || axis == ScrollAxis.Both ? event.deltaX : 0.0;
				var dy = axis == ScrollAxis.Vertical || axis == ScrollAxis.Both ? event.deltaY : 0.0;
				if (axis != ScrollAxis.Vertical && event.modifiers.contains(UiModifier.Shift) && dx == 0) {
					dx = dy;
					dy = 0;
				}
				if (dx != 0 || dy != 0) visibility.value.reveal();
				if (controller.scrollBy(dx, dy)) event.stopPropagation();
			});
			// A touch drag scrolls 1:1 and flings on release. Mouse input has no UiTouchData and keeps its wheel and
			// scrollbar behaviour. The drag claims the pointer (capture and preventDefault) only once it passes the
			// slop, so taps reach their buttons and an inner scroll view keeps a drag from the outer one.
			var touch = context.resourceState(context.id("touch-scroll"), function() return new TouchScrollState(),
				function(_) {}).value;
			viewport.on(UiEventKind.PointerDown, function(event) {
				if (event.button != 0 || !Std.isOfType(event.data, UiTouchData)) return;
				if (touch.tracking && touch.scrolling && touch.pointer != event.pointerId) return;
				controller.stopFling();
				touch.begin(event.pointerId, event.x, event.y);
			});
			viewport.on(UiEventKind.PointerMove, function(event) {
				if (!touch.tracking || touch.pointer != event.pointerId) return;
				if (!touch.scrolling) {
					if (event.defaultPrevented) {
						touch.tracking = false;
						return;
					}
					var movedX = event.x - touch.startX;
					var movedY = event.y - touch.startY;
					var absX = Math.abs(movedX);
					var absY = Math.abs(movedY);
					if (movedX * movedX + movedY * movedY < TouchSlop * TouchSlop) return;
					var canX = axis != ScrollAxis.Vertical && controller.maxScrollX > 0.0;
					var canY = axis != ScrollAxis.Horizontal && controller.maxScrollY > 0.0;
					var claims = axis == ScrollAxis.Both ? canX || canY : axis == ScrollAxis.Vertical ? canY
						&& absY >= absX : canX && absX >= absY;
					if (!claims) {
						touch.tracking = false;
						return;
					}
					touch.scrolling = true;
					touch.lastX = event.x;
					touch.lastY = event.y;
					touch.velocity.reset();
					touch.velocity.add(Sys.time(), event.x, event.y);
					event.capturePointer();
					event.preventDefault();
					return;
				}
				var deltaX = axis != ScrollAxis.Vertical ? touch.lastX - event.x : 0.0;
				var deltaY = axis != ScrollAxis.Horizontal ? touch.lastY - event.y : 0.0;
				touch.lastX = event.x;
				touch.lastY = event.y;
				touch.velocity.add(Sys.time(), event.x, event.y);
				controller.jumpTo(controller.offsetX + deltaX, controller.offsetY + deltaY);
				event.preventDefault();
			});
			viewport.on(UiEventKind.PointerUp, function(event) {
				if (!touch.tracking || touch.pointer != event.pointerId) return;
				var wasScrolling = touch.scrolling;
				touch.tracking = false;
				touch.scrolling = false;
				if (!wasScrolling) return;
				touch.velocity.add(Sys.time(), event.x, event.y);
				touch.velocity.compute(Sys.time());
				controller.fling(axis != ScrollAxis.Vertical ? -touch.velocity.velocityX : 0.0,
					axis != ScrollAxis.Horizontal ? -touch.velocity.velocityY : 0.0);
				event.preventDefault();
			});
			viewport.on(UiEventKind.PointerCancel, function(event) {
				if (!touch.tracking || touch.pointer != event.pointerId) return;
				touch.tracking = false;
				touch.scrolling = false;
			});
			var handleKey = function(event:UiEvent) {
				if (event.defaultPrevented) return;
				var amount = 0.0;
				if (event.key == UiKey.Down) amount = 40.0;
				else if (event.key == UiKey.Up) amount = -40.0;
				else if (event.key == UiKey.PageDown) amount = controller.viewportHeight * 0.9;
				else if (event.key == UiKey.PageUp) amount = -controller.viewportHeight * 0.9;
				else if (event.key == UiKey.Home) {
					if (controller.jumpTo(controller.offsetX, 0.0)) event.preventDefault();
					return;
				} else if (event.key == UiKey.End) {
					if (controller.jumpTo(controller.offsetX, controller.maxScrollY)) event.preventDefault();
					return;
				} else return;
				if (controller.scrollBy(0.0, amount)) event.preventDefault();
			};
			viewport.on(UiEventKind.KeyDown, handleKey);
			viewport.on(UiEventKind.KeyRepeat, handleKey);
			if (scrollbar != null && overlayHost != viewport) {
				scrollbar.on(UiEventKind.KeyDown, handleKey);
				scrollbar.on(UiEventKind.KeyRepeat, handleKey);
				scrollbar.on(UiEventKind.Scroll, function(event) {
					visibility.value.reveal();
					if (controller.scrollBy(0, event.deltaY)) event.stopPropagation();
				});
			}
			return viewport;
		});
	}

	/** One scrollbar implementation shares painting, capture and accessibility for both axes. */
	function addScrollbar(context:BuildContext,
			viewport:RenderNode,
			visibility:ScrollbarVisibilityController,
			vertical:Bool):RenderNode {
		var name = vertical ? "vertical" : "horizontal";
		var trackStyle = new LayoutStyle();
		trackStyle.positioning = LayoutPositioning.Absolute;
		// Above ordinary content, below selection popups (z-index 10).
		trackStyle.zIndex = 4;
		trackStyle.radiusTopLeft = trackStyle.radiusTopRight = ScrollbarHitWidth * 0.5;
		trackStyle.radiusBottomLeft = trackStyle.radiusBottomRight = ScrollbarHitWidth * 0.5;
		var track = context.createNode(context.rootId(name + "-scrollbar-track"), LayoutVisualKind.Box, trackStyle);
		// Layout places the track and the thumb from the controller, once the viewport and its content are laid out.
		track.layout.placer = new ScrollbarPlacer(controller, vertical, false);
		track.setStyleIdentity(new StyleIdentity("scrollbar-track", key.rawValue, key.rawValue, null, [
			"scrollbar",
			name
		]));
		var thumbStyle = new LayoutStyle();
		thumbStyle.positioning = LayoutPositioning.Absolute;
		thumbStyle.zIndex = 5;
		var thumbId = context.id(name + "-scrollbar-thumb");
		var thumb = context.createNode(thumbId, LayoutVisualKind.Box, thumbStyle);
		thumb.layout.placer = new ScrollbarPlacer(controller, vertical, true);
		thumb.setStyleIdentity(new StyleIdentity("scrollbar-thumb", key.rawValue, key.rawValue, null, [
			"scrollbar",
			name
		]));
		var semantics = new Semantics(AccessibilityRole.Slider,
			vertical ? "Vertical scroll position" : "Horizontal scroll position");
		semantics.actions = AccessibilityAction.Increment | AccessibilityAction.Decrement;
		semantics.numericMinimum = 0.0;
		semantics.orientation = vertical ? AccessibilityOrientation.Vertical : AccessibilityOrientation.Horizontal;
		thumb.semantics = semantics;
		var visualStyle = new LayoutStyle();
		visualStyle.positioning = LayoutPositioning.Absolute;
		visualStyle.radiusTopLeft = visualStyle.radiusTopRight = 5.0;
		visualStyle.radiusBottomLeft = visualStyle.radiusBottomRight = 5.0;
		var visual = context.createNode(context.rootId(name + "-scrollbar-thumb-visual"),
			LayoutVisualKind.Box, visualStyle);
		visual.hitTestSelf = false;
		thumb.add(visual);
		track.add(thumb);
		viewport.add(track);
		var maximum = function() return vertical ? controller.maxScrollY : controller.maxScrollX;
		var offset = function() return vertical ? controller.offsetY : controller.offsetX;
		var extent = function() return vertical ? controller.viewportHeight : controller.viewportWidth;
		var jump = function(value:Float) return vertical ? controller.jumpTo(controller.offsetX,
			value) : controller.jumpTo(value,
			controller.offsetY);
		var travel = function() {
			var trackGeometry = track.resolved, thumbGeometry = thumb.resolved;
			if (trackGeometry == null || thumbGeometry == null) return 0.0;
			return Math.max(0.0, vertical ? trackGeometry.height - thumbGeometry.height : trackGeometry.width
				- thumbGeometry.width);
		};
		var updatePaint = function() {
			var opacity = visibility.opacity;
			var active = visibility.hovered || visibility.dragging || visibility.focused;
			var color = context.theme.tokens.textSecondary;
			var nextTrackStyle = track.layout.style;
			nextTrackStyle.background = Color.rgba(color.red,
				color.green,
				color.blue,
				color.alpha * opacity * (active ? 0.06 : 0.0));
			var nextVisualStyle = visual.layout.style;
			if (vertical) {
				nextVisualStyle.width = LayoutAxis.fixed(active ? 10.0 : 8.0);
				nextVisualStyle.height = LayoutAxis.grow();
				nextVisualStyle.positionX = active ? 1.0 : 2.0;
			} else {
				nextVisualStyle.height = LayoutAxis.fixed(active ? 10.0 : 8.0);
				nextVisualStyle.width = LayoutAxis.grow();
				nextVisualStyle.positionY = active ? 1.0 : 2.0;
			}
			nextVisualStyle.background = Color.rgba(color.red,
				color.green,
				color.blue,
				color.alpha * opacity * (visibility.dragging ? 0.85 : active ? 0.65 : 0.4));
			thumb.hitTestSelf = opacity > 0;
		};
		// Fades and hover change only these nodes, so they are edited in place: the frame lays them out and paints them
		// without rebuilding the view or any cache around it.
		visibility.attach(context.animations, function() {
			context.willEditRetained(track);
			context.willEditRetained(thumb);
			context.willEditRetained(visual);
			updatePaint();
		});
		updatePaint();
		track.onTargetBubble(UiEventKind.HoverEnter, function(event) {
			if (event.target.equals(track.id)) visibility.setHovered(true);
		});
		track.onTargetBubble(UiEventKind.HoverLeave, function(event) {
			if (event.target.equals(track.id)) visibility.setHovered(false);
		});
		thumb.on(UiEventKind.Focus, function(_) visibility.setFocused(true));
		thumb.on(UiEventKind.Blur, function(_) visibility.setFocused(false));
		thumb.on(UiEventKind.FocusLost, function(_) visibility.setFocused(false));
		var dragState:State<ScrollbarDragState> = context.resourceState(thumbId,
			function() return new ScrollbarDragState(), function(_) {});
		thumb.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0) return;
			var drag = dragState.value;
			drag.dragging = true;
			drag.pointer = drag.lastPointer = vertical ? event.y : event.x;
			drag.offset = offset();
			drag.maximum = maximum();
			drag.travel = travel();
			visibility.setFocused(false);
			visibility.setDragging(true);
			dragState.update(drag);
			event.capturePointer();
			event.stopPropagation();
			event.preventDefault();
		});
		track.onResolved(function(_) {
			var drag = dragState.value;
			if (drag.dragging && (drag.maximum != maximum() || drag.travel != travel())) {
				drag.pointer = drag.lastPointer;
				drag.offset = offset();
				drag.maximum = maximum();
				drag.travel = travel();
			}
		});
		thumb.on(UiEventKind.PointerMove, function(event) {
			var drag = dragState.value;
			drag.lastPointer = vertical ? event.y : event.x;
			if (!drag.dragging || travel() <= 0.0) return;
			jump(drag.offset + (drag.lastPointer - drag.pointer) * maximum() / travel());
			event.preventDefault();
		});
		var finish = function(event:UiEvent) {
			if (!dragState.value.dragging) return;
			dragState.value.dragging = false;
			visibility.setDragging(false);
			dragState.update(dragState.value);
			event.releasePointer();
			event.preventDefault();
		};
		thumb.on(UiEventKind.PointerUp, finish);
		thumb.on(UiEventKind.PointerCancel, finish);
		thumb.on(UiEventKind.AccessibilityIncrement, function(event) {
			if (jump(offset() + Math.max(40.0, extent() * 0.1))) event.preventDefault();
		});
		thumb.on(UiEventKind.AccessibilityDecrement, function(event) {
			if (jump(offset() - Math.max(40.0, extent() * 0.1))) event.preventDefault();
		});
		track.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || track.resolved == null) return;
			visibility.reveal();
			var geometry:ResolvedLayoutItem = cast track.resolved;
			var local = geometry.viewportToLayout(event.x, event.y);
			var pointer = vertical ? local.y - geometry.y : local.x - geometry.x;
			var thumbGeometry = thumb.resolved;
			var thumbExtent = thumbGeometry == null ? 0.0 : vertical ? thumbGeometry.height : thumbGeometry.width;
			jump(travel() <= 0 ? 0 : Math.max(0.0,
				Math.min(travel(), pointer - thumbExtent * 0.5)) / travel() * maximum());
			event.preventDefault();
		});
		return track;
	}

	/** The thumb's accessible range and focusability follow the controller's settled metrics. */
	function syncScrollbar(track:RenderNode, vertical:Bool):Void {
		var thumb = track.children[0];
		var maximum = vertical ? controller.maxScrollY : controller.maxScrollX;
		var semantics:Semantics = cast thumb.semantics;
		semantics.numericMaximum = maximum;
		semantics.numericValue = vertical ? controller.offsetY : controller.offsetX;
		thumb.focusable = maximum > 0 && (vertical ? controller.viewportHeight : controller.viewportWidth) > 0;
	}

}

private class ScrollbarDragState {
	public var dragging:Bool = false;
	public var pointer:Float = 0.0;
	public var lastPointer:Float = 0.0;
	public var offset:Float = 0.0;
	public var maximum:Float = 0.0;
	public var travel:Float = 0.0;
	public function new() {}
}

private class TouchScrollState {
	public var tracking:Bool = false;
	public var scrolling:Bool = false;
	public var pointer:Int = 0;
	public var startX:Float = 0.0;
	public var startY:Float = 0.0;
	public var lastX:Float = 0.0;
	public var lastY:Float = 0.0;
	public final velocity:VelocityTracker = new VelocityTracker();
	public function new() {}

	public function begin(pointer:Int, x:Float, y:Float):Void {
		this.pointer = pointer;
		tracking = true;
		scrolling = false;
		startX = lastX = x;
		startY = lastY = y;
		velocity.reset();
	}
}

/** Axes whose content may move inside a ScrollView viewport. */
enum ScrollAxis {
	/** Content scrolls up and down. */
	Vertical;
	/** Content scrolls left and right. */
	Horizontal;
	/** Content scrolls both ways. */
	Both;
}

/** When scrollbars show; `Auto` reveals them on pane hover or scroll activity. */
enum ScrollbarVisibility {
	/** Scrollbars show while the pane is hovered or scrolling. */
	Auto;
	/** Scrollbars always show. */
	Always;
	/** Scrollbars never show; the content still scrolls. */
	Hidden;
}

/** Mount-owned binding; replacing or unmounting a viewport retires its animation. */
internal class ScrollBinding implements Disposable {
	var controller:Null<ScrollController>;
	public function new() {}
	public function attach(value:ScrollController, scheduler:AnimationScheduler, changed:ScrollController->Void):Void {
		if (controller != value) {
			dispose();
			controller = value;
		}
		value.bind(changed, scheduler, this);
	}
	public function dispose():Void {
		if (controller != null) controller.unbind(this);
		controller = null;
	}
}

/**
 * A scroll view's content offset, settled by layout: the controller learns the viewport's size and the content's (or the
 * extent its provider gives for virtual content) and clamps its offset to them before the content is placed.
 */
private class ContentScroll implements LayoutScroll {
	final controller:ScrollController;
	final extent:Null<(Float, Float) -> {width:Float, height:Float}>;

	public function new(controller:ScrollController, extent:Null<(Float, Float) -> {width:Float, height:Float}>) {
		this.controller = controller;
		this.extent = extent;
	}

	public function settle(viewportWidth:Float, viewportHeight:Float, contentWidth:Float, contentHeight:Float,
			content:haxeon.ui.LayoutScroll.LayoutLocator):Void {
		var provider = extent;
		if (provider != null) {
			var intrinsic = provider(viewportWidth, viewportHeight);
			contentWidth = Math.max(viewportWidth, intrinsic.width);
			contentHeight = Math.max(viewportHeight, intrinsic.height);
		}
		@:privateAccess controller.updateMetrics(viewportWidth, viewportHeight, contentWidth, contentHeight);
		@:privateAccess controller.settleReveal(content);
	}

	public function scrollX():Float return controller.offsetX;

	public function scrollY():Float return controller.offsetY;
}

/**
 * Places a scrollbar's track along its viewport's edge, or its thumb along the track, from the scroll controller's
 * settled metrics; both hide when there is nothing to scroll.
 */
private class ScrollbarPlacer implements LayoutPlacer {
	final controller:ScrollController;
	final vertical:Bool;
	final thumb:Bool;

	public function new(controller:ScrollController, vertical:Bool, thumb:Bool) {
		this.controller = controller;
		this.vertical = vertical;
		this.thumb = thumb;
	}

	public function place(parentWidth:Float, parentHeight:Float, out:LayoutPlacement):Void {
		var hitWidth = @:privateAccess ScrollView.ScrollbarHitWidth, inset = @:privateAccess ScrollView.ScrollbarInset;
		var viewportExtent = vertical ? controller.viewportHeight : controller.viewportWidth;
		var contentExtent = vertical ? controller.contentHeight : controller.contentWidth;
		var maximum = vertical ? controller.maxScrollY : controller.maxScrollX;
		var length = Math.max(0.0, viewportExtent - inset * 2.0);
		out.shown = maximum > 0 && viewportExtent > 0;
		if (!thumb) {
			var cross = Math.max(0, (vertical ? parentWidth : parentHeight) - hitWidth - inset);
			out.x = vertical ? cross : inset;
			out.y = vertical ? inset : cross;
			out.width = vertical ? hitWidth : length;
			out.height = vertical ? length : hitWidth;
			return;
		}
		var thumbLength = contentExtent <= 0 ? 0 : Math.min(length,
			Math.max(24.0, length * viewportExtent / contentExtent));
		var offset = vertical ? controller.offsetY : controller.offsetX;
		var along = maximum <= 0 ? 0 : offset / maximum * Math.max(0, length - thumbLength);
		out.x = vertical ? 0 : along;
		out.y = vertical ? along : 0;
		out.width = vertical ? hitWidth : thumbLength;
		out.height = vertical ? thumbLength : hitWidth;
	}
}
