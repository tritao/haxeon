package haxeon.ui.widgets.scroll;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.Transform2D;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.semantics.AccessibilityOrientation;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleState;

/** Clipped Haxe scroll container translated from its persistent controller offset. */
class ScrollView implements View {
	static inline var ScrollbarHitWidth:Float = 12.0;
	static inline var ScrollbarInset:Float = 2.0;
	final key:Key;
	final child:View;
	final axis:Int;
	final suppliedController:Bool;
	public final style:LayoutStyle;
	public var controller(default, null):ScrollController;
	public var onScroll:UiEvent->Void;
	/** Shows an interactive overlay scrollbar when vertical content overflows. */
	public var showScrollbar:Bool;
	/** Expand content to fill a short viewport while retaining intrinsic scroll overflow. */
	public var fillViewport:Bool = false;
	/** Optional intrinsic content dimensions for clipped or virtualized document widgets. */
	public var contentExtentProvider:Null<(Float, Float)->{width:Float, height:Float}>;
	/** Null inherits the application environment policy. */
	public var scrollbarVisibility:Null<Int> = null;
	/** Optional non-scrolling ancestor with the same vertical extent. */
	public var scrollbarOverlayHost:Null<RenderNode> = null;

	public function new(key:String, child:View, ?style:LayoutStyle,
			axis:Int = ScrollAxis.Vertical, ?controller:ScrollController) {
		if (child == null || (axis != ScrollAxis.Vertical && axis != ScrollAxis.Horizontal &&
			axis != ScrollAxis.Both))
			throw "ScrollView requires a child and a supported axis";
		this.key = new Key(key);
		this.child = child;
		this.axis = axis;
		this.style = style == null ? new LayoutStyle() : style.copy();
		suppliedController = controller != null;
		this.controller = controller == null ? new ScrollController() : controller;
		onScroll = null;
		showScrollbar = true;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var viewportStyle = style.copy();
			var id = context.id("scroll");
			var flags = context.interactionStates.get(id);
			var computed = context.resolveStyle(new StyleTarget("scroll-view", key.value, key.value,
				null, ["scroll-view"], flags), viewportStyle);
			var viewport = new RenderNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
			viewport.setStyleIdentity("scroll-view", key.value, key.value, null, ["scroll-view"]);
			viewport.states = flags;
			viewport.computedStyle = computed;
			viewport.focusable = true;
			var semantics = new Semantics(AccessibilityRole.ScrollArea);
			semantics.actions = AccessibilityAction.ScrollForward | AccessibilityAction.ScrollBackward;
			viewport.semantics = semantics;
			viewport.layout.style.clipHorizontal = viewport.layout.style.clipHorizontal ||
				axis == ScrollAxis.Horizontal || axis == ScrollAxis.Both;
			viewport.layout.style.clipVertical = viewport.layout.style.clipVertical ||
				axis == ScrollAxis.Vertical || axis == ScrollAxis.Both;
			if (!suppliedController) {
				var stored:State<ScrollController> = context.resourceState(viewport.id, function() return controller, function(_) {});
				controller = stored.value;
			}
			// The offset is applied to the content in place after layout (see onResolved below), so a scroll needs a new
			// frame but not a rebuild: bumping the state revision here would invalidate every cached subtree around it.
			var binding = context.resourceState(context.id("controller-binding"), function() return new ScrollBinding(),
				function(value) value.dispose());
			var visibility = context.resourceState(context.id("scrollbar-visibility"), function() return new ScrollbarVisibilityController(), function(value) value.dispose());
			var visibilityChanged = function() { visibility.update(visibility.value); context.commands.refresh(); };
			visibility.value.attach(context.animations, visibilityChanged);
			visibility.value.bindSource(controller);
			var policy:Int = scrollbarVisibility == null ? context.environment.scrollbarVisibility : scrollbarVisibility;
			visibility.value.configure(showScrollbar ? policy : ScrollbarVisibility.Hidden, context.environment.reducedMotion);

			visibility.value.setViewportHovered((flags & StyleState.Hovered) != 0);
			viewport.on(UiEventKind.HoverEnter, function(event) {
				if (event.target.equals(viewport.id)) visibility.value.setViewportHovered(true);
			});
			viewport.on(UiEventKind.HoverLeave, function(event) {
				if (event.target.equals(viewport.id)) visibility.value.setViewportHovered(false);
			});

			var contentStyle = new LayoutStyle();
			// Explicit document extents must not become the viewport's minimum layout size.
			// Keep that content outside parent flow; its provider owns the scroll range.
			if (contentExtentProvider != null) contentStyle.positioning = LayoutPositioning.Absolute;
			contentStyle.width = axis == ScrollAxis.Vertical ? LayoutAxis.stretch() : fillViewport ? LayoutAxis.grow() : LayoutAxis.fit();
			contentStyle.height = axis == ScrollAxis.Horizontal || fillViewport ? LayoutAxis.grow() : LayoutAxis.fit();
			contentStyle.transform = Transform2D.identity().translated(-controller.offsetX,
				-controller.offsetY);
			var translatedContent = new RenderNode(context.id("scroll-content"),
				LayoutVisualKind.Box, contentStyle);
			var content = context.withStyleParent(computed, function() {
				return context.withScope(new Key("content"), function() return child.build(context));
			});
			translatedContent.add(content);
			var horizontalVisibility = context.resourceState(context.id("horizontal-scrollbar-visibility"),
				function() return new ScrollbarVisibilityController(), function(value) value.dispose());
			horizontalVisibility.value.bindSource(controller);
			horizontalVisibility.value.configure(showScrollbar ? policy : ScrollbarVisibility.Hidden, context.environment.reducedMotion);
			horizontalVisibility.value.setViewportHovered((flags & StyleState.Hovered) != 0);
			viewport.on(UiEventKind.HoverEnter, function(event) { if (event.target.equals(viewport.id)) horizontalVisibility.value.setViewportHovered(true); });
			viewport.on(UiEventKind.HoverLeave, function(event) { if (event.target.equals(viewport.id)) horizontalVisibility.value.setViewportHovered(false); });
			binding.value.attach(controller, context.animations, function(_) {
				translatedContent.layout.style.transform = Transform2D.identity().translated(-controller.offsetX, -controller.offsetY);
				visibility.value.reveal();
				horizontalVisibility.value.reveal();
				context.commands.refresh();
			});

			viewport.add(translatedContent);
			var overlayHost = scrollbarOverlayHost == null ? viewport : scrollbarOverlayHost;
			var scrollbar = showScrollbar && policy != ScrollbarVisibility.Hidden && axis != ScrollAxis.Horizontal
				? addScrollbar(context, overlayHost, visibility.value, visibilityChanged, true) : null;

			var horizontal = showScrollbar && policy != ScrollbarVisibility.Hidden && axis != ScrollAxis.Vertical
				? addScrollbar(context, overlayHost, horizontalVisibility.value, visibilityChanged, false) : null;
			translatedContent.onResolved(function(geometry) {
				var viewportGeometry:ResolvedLayoutItem = cast viewport.resolved;
				// The viewport's content bounds include the overlay scrollbar. Its
				// previous track height can otherwise look like content overflow.
				var contentWidth = Math.max(geometry.width,
					geometry.contentBounds.x + geometry.contentBounds.width);
				var contentHeight = Math.max(geometry.height,
					geometry.contentBounds.y + geometry.contentBounds.height);
				if (contentExtentProvider != null) {
					var intrinsic = contentExtentProvider(viewportGeometry.width, viewportGeometry.height);
					contentWidth = Math.max(viewportGeometry.width, intrinsic.width);
					contentHeight = Math.max(viewportGeometry.height, intrinsic.height);
				}
				// Clamping notifies the binding and mutates the style; compare with the pre-clamp transform.
				var transform = translatedContent.layout.style.transform;
				controller.updateMetrics(viewportGeometry.width, viewportGeometry.height,
					contentWidth, contentHeight);
				var nextTransform = Transform2D.identity().translated(-controller.offsetX,
					-controller.offsetY);
				if (transform.tx != nextTransform.tx || transform.ty != nextTransform.ty) {
					translatedContent.layout.style.transform = nextTransform;
					context.requestLayoutFeedback();
				}
				visibility.value.setAvailable(scrollbar != null && controller.maxScrollY > 0 && controller.viewportHeight > 0);
				if (scrollbar != null && updateScrollbar(scrollbar, overlayHost.resolved == null ? controller.viewportWidth : overlayHost.resolved.width, overlayHost.resolved == null ? controller.viewportHeight : overlayHost.resolved.height, true))
					context.requestLayoutFeedback();
				horizontalVisibility.value.setAvailable(horizontal != null && controller.maxScrollX > 0 && controller.viewportWidth > 0);
				if (horizontal != null && updateScrollbar(horizontal, overlayHost.resolved == null ? controller.viewportWidth : overlayHost.resolved.width,
					overlayHost.resolved == null ? controller.viewportHeight : overlayHost.resolved.height, false)) context.requestLayoutFeedback();
			});
			viewport.on(UiEventKind.Scroll, function(event) {
				if (onScroll != null)
					onScroll(event);
				if (event.defaultPrevented)
					return;
				var dx = axis == ScrollAxis.Horizontal || axis == ScrollAxis.Both ? event.deltaX : 0.0;
				var dy = axis == ScrollAxis.Vertical || axis == ScrollAxis.Both ? event.deltaY : 0.0;
				if (axis != ScrollAxis.Vertical && (event.modifiers & UiModifier.Shift) != 0 && dx == 0) { dx = dy; dy = 0; }
				if (dx != 0 || dy != 0) visibility.value.reveal();
				if (controller.scrollBy(dx, dy))
					event.stopPropagation();
			});
			var handleKey = function(event:UiEvent) {
				if (event.defaultPrevented)
					return;
				var amount = 0.0;
				if (event.key == UiKey.Down)
					amount = 40.0;
				else if (event.key == UiKey.Up)
					amount = -40.0;
				else if (event.key == UiKey.PageDown)
					amount = controller.viewportHeight * 0.9;
				else if (event.key == UiKey.PageUp)
					amount = -controller.viewportHeight * 0.9;
				else if (event.key == UiKey.Home) {
					if (controller.jumpTo(controller.offsetX, 0.0))
						event.preventDefault();
					return;
				} else if (event.key == UiKey.End) {
					if (controller.jumpTo(controller.offsetX, controller.maxScrollY))
						event.preventDefault();
					return;
				} else
					return;
				if (controller.scrollBy(0.0, amount))
					event.preventDefault();
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
	function addScrollbar(context:BuildContext, viewport:RenderNode, visibility:ScrollbarVisibilityController,
			changed:Void->Void, vertical:Bool):RenderNode {
		var name = vertical ? "vertical" : "horizontal";
		var trackStyle = new LayoutStyle();
		trackStyle.positioning = LayoutPositioning.Absolute;
		trackStyle.zIndex = 100;
		trackStyle.radiusTopLeft = trackStyle.radiusTopRight = ScrollbarHitWidth * 0.5;
		trackStyle.radiusBottomLeft = trackStyle.radiusBottomRight = ScrollbarHitWidth * 0.5;
		var track = new RenderNode(context.id(name + "-scrollbar-track"), LayoutVisualKind.Box, trackStyle);
		track.setStyleIdentity("scrollbar-track", key.value, key.value, null, ["scrollbar", name]);
		var thumbStyle = new LayoutStyle();
		thumbStyle.positioning = LayoutPositioning.Absolute;
		thumbStyle.zIndex = 101;
		var thumbId = context.id(name + "-scrollbar-thumb");
		var thumb = new RenderNode(thumbId, LayoutVisualKind.Box, thumbStyle);
		thumb.setStyleIdentity("scrollbar-thumb", key.value, key.value, null, ["scrollbar", name]);
		var semantics = new Semantics(AccessibilityRole.Slider, vertical ? "Vertical scroll position" : "Horizontal scroll position");
		semantics.actions = AccessibilityAction.Increment | AccessibilityAction.Decrement;
		semantics.numericMinimum = 0.0;
		semantics.orientation = vertical ? AccessibilityOrientation.Vertical : AccessibilityOrientation.Horizontal;
		thumb.semantics = semantics;
		var visualStyle = new LayoutStyle();
		visualStyle.positioning = LayoutPositioning.Absolute;
		visualStyle.radiusTopLeft = visualStyle.radiusTopRight = 5.0;
		visualStyle.radiusBottomLeft = visualStyle.radiusBottomRight = 5.0;
		var visual = new RenderNode(context.id(name + "-scrollbar-thumb-visual"), LayoutVisualKind.Box, visualStyle);
		visual.hitTestSelf = false;
		thumb.add(visual);
		track.add(thumb);
		viewport.add(track);
		var maximum = function() return vertical ? controller.maxScrollY : controller.maxScrollX;
		var offset = function() return vertical ? controller.offsetY : controller.offsetX;
		var extent = function() return vertical ? controller.viewportHeight : controller.viewportWidth;
		var jump = function(value:Float) return vertical ? controller.jumpTo(controller.offsetX, value) : controller.jumpTo(value, controller.offsetY);
		var travel = function() return Math.max(0.0, vertical ? trackStyle.height.value - thumbStyle.height.value : trackStyle.width.value - thumbStyle.width.value);
		var updatePaint = function() {
			var opacity = visibility.opacity;
			var active = visibility.hovered || visibility.dragging || visibility.focused;
			var color = context.theme.tokens.textSecondary;
			trackStyle.background = Color.rgba(color.red, color.green, color.blue, color.alpha * opacity * (active ? 0.06 : 0.0));
			if (vertical) {
				visualStyle.width = LayoutAxis.fixed(active ? 10.0 : 8.0);
				visualStyle.height = LayoutAxis.grow();
				visualStyle.positionX = active ? 1.0 : 2.0;
			} else {
				visualStyle.height = LayoutAxis.fixed(active ? 10.0 : 8.0);
				visualStyle.width = LayoutAxis.grow();
				visualStyle.positionY = active ? 1.0 : 2.0;
			}
			visualStyle.background = Color.rgba(color.red, color.green, color.blue, color.alpha * opacity * (visibility.dragging ? 0.85 : active ? 0.65 : 0.4));
			thumb.hitTestSelf = opacity > 0;
		};
		visibility.attach(context.animations, function() { updatePaint(); changed(); });
		updatePaint();
		track.on(UiEventKind.HoverEnter, function(event) { if (event.target.equals(track.id)) visibility.setHovered(true); });
		track.on(UiEventKind.HoverLeave, function(event) { if (event.target.equals(track.id)) visibility.setHovered(false); });
		thumb.on(UiEventKind.Focus, function(_) visibility.setFocused(true));
		thumb.on(UiEventKind.Blur, function(_) visibility.setFocused(false));
		thumb.on(UiEventKind.FocusLost, function(_) visibility.setFocused(false));
		var dragState:State<ScrollbarDragState> = context.resourceState(thumbId, function() return new ScrollbarDragState(), function(_) {});
		thumb.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0) return;
			var drag = dragState.value;
			drag.dragging = true;
			drag.pointer = drag.lastPointer = vertical ? event.y : event.x;
			drag.offset = offset(); drag.maximum = maximum(); drag.travel = travel();
			visibility.setFocused(false); visibility.setDragging(true);
			dragState.update(drag);
			event.capturePointer(); event.stopPropagation(); event.preventDefault();
		});
		track.onResolved(function(_) {
			var drag = dragState.value;
			if (drag.dragging && (drag.maximum != maximum() || drag.travel != travel())) {
				drag.pointer = drag.lastPointer; drag.offset = offset();
				drag.maximum = maximum(); drag.travel = travel();
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
			dragState.value.dragging = false; visibility.setDragging(false);
			dragState.update(dragState.value); event.releasePointer(); event.preventDefault();
		};
		thumb.on(UiEventKind.PointerUp, finish); thumb.on(UiEventKind.PointerCancel, finish);
		thumb.on(UiEventKind.AccessibilityIncrement, function(event) { if (jump(offset() + Math.max(40.0, extent() * 0.1))) event.preventDefault(); });
		thumb.on(UiEventKind.AccessibilityDecrement, function(event) { if (jump(offset() - Math.max(40.0, extent() * 0.1))) event.preventDefault(); });
		track.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || track.resolved == null) return;
			visibility.reveal();
			var geometry:ResolvedLayoutItem = cast track.resolved;
			var local = geometry.viewportToLayout(event.x, event.y);
			var pointer = vertical ? local.y - geometry.y : local.x - geometry.x;
			var thumbExtent = vertical ? thumbStyle.height.value : thumbStyle.width.value;
			jump(travel() <= 0 ? 0 : Math.max(0.0, Math.min(travel(), pointer - thumbExtent * 0.5)) / travel() * maximum());
			event.preventDefault();
		});
		updateScrollbar(track, controller.viewportWidth, controller.viewportHeight, vertical);
		return track;
	}

	function updateScrollbar(track:RenderNode, width:Float, height:Float, vertical:Bool):Bool {
		var thumb = track.children[0], trackStyle = track.layout.style, thumbStyle = thumb.layout.style;
		var viewportExtent = vertical ? controller.viewportHeight : controller.viewportWidth;
		var contentExtent = vertical ? controller.contentHeight : controller.contentWidth;
		var maximum = vertical ? controller.maxScrollY : controller.maxScrollX;
		var offset = vertical ? controller.offsetY : controller.offsetX;
		var length = Math.max(0.0, viewportExtent - ScrollbarInset * 2.0);
		var thumbLength = contentExtent <= 0 ? 0 : Math.min(length, Math.max(24.0, length * viewportExtent / contentExtent));
		var along = maximum <= 0 ? 0 : offset / maximum * Math.max(0, length - thumbLength);
		var cross = Math.max(0, (vertical ? width : height) - ScrollbarHitWidth - ScrollbarInset);
		var visible = maximum > 0 && viewportExtent > 0;
		var changed = trackStyle.visible != visible || (vertical ?
			trackStyle.height.value != length || thumbStyle.height.value != thumbLength || thumbStyle.positionY != along || trackStyle.positionX != cross :
			trackStyle.width.value != length || thumbStyle.width.value != thumbLength || thumbStyle.positionX != along || trackStyle.positionY != cross);
		trackStyle.positionX = vertical ? cross : ScrollbarInset;
		trackStyle.positionY = vertical ? ScrollbarInset : cross;
		trackStyle.width = LayoutAxis.fixed(vertical ? ScrollbarHitWidth : length);
		trackStyle.height = LayoutAxis.fixed(vertical ? length : ScrollbarHitWidth);
		thumbStyle.positionX = vertical ? 0 : along;
		thumbStyle.positionY = vertical ? along : 0;
		thumbStyle.width = LayoutAxis.fixed(vertical ? ScrollbarHitWidth : thumbLength);
		thumbStyle.height = LayoutAxis.fixed(vertical ? thumbLength : ScrollbarHitWidth);
		trackStyle.visible = thumbStyle.visible = thumb.focusable = visible;
		var semantics:Semantics = cast thumb.semantics;
		semantics.numericMaximum = maximum; semantics.numericValue = offset;
		return changed;
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
