package nativekit.ui.widgets.scroll;

import Color;
import LayoutAxis;
import LayoutPositioning;
import LayoutStyle;
import LayoutVisualKind;
import ResolvedLayoutItem;
import Transform2D;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.State;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.View;
import nativekit.ui.semantics.AccessibilityAction;
import nativekit.ui.semantics.AccessibilityRole;
import nativekit.ui.semantics.Semantics;
import nativekit.ui.semantics.AccessibilityOrientation;
import nativekit.ui.style.StyleTarget;

/** Clipped Haxe scroll container translated from its persistent controller offset. */
class ScrollView implements View {
	final key:Key;
	final child:View;
	final axis:Int;
	final suppliedController:Bool;
	public final style:LayoutStyle;
	public var controller(default, null):ScrollController;
	public var onScroll:UiEvent->Void;
	/** Shows an interactive overlay scrollbar when vertical content overflows. */
	public var showScrollbar:Bool;
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

			var contentStyle = new LayoutStyle();
			contentStyle.width = axis == ScrollAxis.Vertical ? LayoutAxis.stretch() : LayoutAxis.fit();
			contentStyle.height = axis == ScrollAxis.Horizontal ? LayoutAxis.grow() : LayoutAxis.fit();
			contentStyle.transform = Transform2D.identity().translated(-controller.offsetX,
				-controller.offsetY);
			var translatedContent = new RenderNode(context.id("scroll-content"),
				LayoutVisualKind.Box, contentStyle);
			var content = context.withStyleParent(computed, function() {
				return context.withScope(new Key("content"), function() return child.build(context));
			});
			translatedContent.add(content);
			binding.value.attach(controller, context.animations, function(_) {
				translatedContent.layout.style.transform = Transform2D.identity().translated(-controller.offsetX, -controller.offsetY);
				visibility.value.reveal();
				context.commands.refresh();
			});

			viewport.add(translatedContent);
			var overlayHost = scrollbarOverlayHost == null ? viewport : scrollbarOverlayHost;
			var scrollbar = showScrollbar && policy != ScrollbarVisibility.Hidden && axis != ScrollAxis.Horizontal
				? addVerticalScrollbar(context, overlayHost, visibility.value, visibilityChanged) : null;

			translatedContent.onResolved(function(geometry) {
				var viewportGeometry:ResolvedLayoutItem = cast viewport.resolved;
				// The viewport's content bounds include the overlay scrollbar. Its
				// previous track height can otherwise look like content overflow.
				var contentWidth = Math.max(geometry.width,
					geometry.contentBounds.x + geometry.contentBounds.width);
				var contentHeight = Math.max(geometry.height,
					geometry.contentBounds.y + geometry.contentBounds.height);
				controller.updateMetrics(viewportGeometry.width, viewportGeometry.height,
					contentWidth, contentHeight);
				var nextTransform = Transform2D.identity().translated(-controller.offsetX,
					-controller.offsetY);
				var transform = translatedContent.layout.style.transform;
				if (transform.tx != nextTransform.tx || transform.ty != nextTransform.ty) {
					translatedContent.layout.style.transform = nextTransform;
					context.requestLayoutFeedback();
				}
				visibility.value.setAvailable(scrollbar != null && controller.maxScrollY > 0 && controller.viewportHeight > 0);
				if (scrollbar != null && updateVerticalScrollbar(scrollbar, overlayHost.resolved == null ? controller.viewportWidth : overlayHost.resolved.width))
					context.requestLayoutFeedback();
			});
			viewport.on(UiEventKind.Scroll, function(event) {
				if (onScroll != null)
					onScroll(event);
				if (event.defaultPrevented)
					return;
				var dx = axis == ScrollAxis.Horizontal || axis == ScrollAxis.Both ? event.deltaX : 0.0;
				var dy = axis == ScrollAxis.Vertical || axis == ScrollAxis.Both ? event.deltaY : 0.0;
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

	function addVerticalScrollbar(context:BuildContext, viewport:RenderNode, visibility:ScrollbarVisibilityController, changed:Void->Void):RenderNode {
		var trackWidth = 10.0;
		var inset = 2.0;
		var trackHeight = Math.max(0.0, controller.viewportHeight - inset * 2.0);
		var thumbHeight = controller.contentHeight <= 0.0 ? 0.0 : Math.max(24.0,
			trackHeight * controller.viewportHeight / controller.contentHeight);
		if (thumbHeight > trackHeight)
			thumbHeight = trackHeight;
		var travel = Math.max(0.0, trackHeight - thumbHeight);
		var thumbY = inset + (controller.maxScrollY <= 0.0 ? 0.0 :
			controller.offsetY / controller.maxScrollY * travel);
		var trackStyle = new LayoutStyle();
		trackStyle.positioning = LayoutPositioning.Absolute;
		trackStyle.positionX = Math.max(0.0, controller.viewportWidth - trackWidth - inset);
		trackStyle.positionY = inset;
		trackStyle.width = LayoutAxis.fixed(trackWidth);
		trackStyle.height = LayoutAxis.fixed(trackHeight);
		trackStyle.visible = controller.maxScrollY > 0.0 && controller.viewportHeight > 0.0;
		trackStyle.background = context.theme.controlUnselected;
		trackStyle.radiusTopLeft = trackStyle.radiusTopRight = trackWidth * 0.5;
		trackStyle.radiusBottomLeft = trackStyle.radiusBottomRight = trackWidth * 0.5;
		trackStyle.zIndex = 100;
		var track = new RenderNode(context.id("vertical-scrollbar-track"),
			LayoutVisualKind.Box, trackStyle);
		track.setStyleIdentity("scrollbar-track", key.value, key.value, null,
			["scrollbar", "vertical"]);
		var thumbStyle = new LayoutStyle();
		thumbStyle.positioning = LayoutPositioning.Absolute;
		thumbStyle.positionX = 1.0;
		thumbStyle.positionY = thumbY - inset;
		thumbStyle.width = LayoutAxis.fixed(trackWidth - 2.0);
		thumbStyle.height = LayoutAxis.fixed(thumbHeight);
		thumbStyle.visible = trackStyle.visible;
		thumbStyle.background = context.theme.accent;
		thumbStyle.radiusTopLeft = thumbStyle.radiusTopRight = (trackWidth - 2.0) * 0.5;
		thumbStyle.radiusBottomLeft = thumbStyle.radiusBottomRight = (trackWidth - 2.0) * 0.5;
		thumbStyle.zIndex = 101;
		var thumbId = context.id("vertical-scrollbar-thumb");
		var thumb = new RenderNode(thumbId, LayoutVisualKind.Box, thumbStyle);
		thumb.setStyleIdentity("scrollbar-thumb", key.value, key.value, null,
			["scrollbar", "vertical"]);
		thumb.focusable = trackStyle.visible;
		var semantics = new Semantics(AccessibilityRole.Slider, "Vertical scroll position");
		semantics.actions = AccessibilityAction.Increment | AccessibilityAction.Decrement;
		semantics.numericMinimum = 0.0;
		semantics.numericMaximum = controller.maxScrollY;
		semantics.numericValue = controller.offsetY;
		semantics.orientation = AccessibilityOrientation.Vertical;
		thumb.semantics = semantics;
		var updatePaint = function() {
			var opacity = visibility.opacity;
			var trackColor = context.theme.controlUnselected, thumbColor = context.theme.accent;
			track.layout.style.background = Color.rgba(trackColor.red, trackColor.green, trackColor.blue, trackColor.alpha * opacity);
			thumb.layout.style.background = Color.rgba(thumbColor.red, thumbColor.green, thumbColor.blue, thumbColor.alpha * opacity);
			// Only the narrow track receives pointer input while the thumb is hidden.
			thumb.hitTestSelf = opacity > 0;
		};
		visibility.attach(context.animations, function() { thumb.hitTestSelf = visibility.opacity > 0; changed(); });
		updatePaint();
		track.on(UiEventKind.HoverEnter, function(event) { if (event.target.equals(track.id)) visibility.setHovered(true); });
		track.on(UiEventKind.HoverLeave, function(event) { if (event.target.equals(track.id)) visibility.setHovered(false); });
		thumb.on(UiEventKind.Focus, function(_) visibility.setFocused(true));
		thumb.on(UiEventKind.Blur, function(_) visibility.setFocused(false));
		thumb.on(UiEventKind.FocusLost, function(_) visibility.setFocused(false));
		var dragState:State<ScrollbarDragState> = context.resourceState(thumbId,
			function() return new ScrollbarDragState(), function(_) {});
		thumb.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0)
				return;
			dragState.value.dragging = true;
			visibility.setFocused(false);
			visibility.setDragging(true);
			dragState.value.pointerY = event.y;
			dragState.value.lastPointerY = event.y;
			dragState.value.offsetY = controller.offsetY;
			dragState.value.maxScrollY = controller.maxScrollY;
			dragState.value.travel = Math.max(0.0, track.layout.style.height.value - thumb.layout.style.height.value);
			dragState.update(dragState.value);
			event.capturePointer();
			event.stopPropagation();
			event.preventDefault();
		});
		// Metrics may change while the pointer is captured (window resize or reflow).
		// Rebase at the last pointer position so subsequent movement uses the new range.
		track.onResolved(function(_) {
			var drag = dragState.value;
			var travel = Math.max(0.0, track.layout.style.height.value - thumb.layout.style.height.value);
			if (drag.dragging && (drag.maxScrollY != controller.maxScrollY || drag.travel != travel)) {
				drag.pointerY = drag.lastPointerY;
				drag.offsetY = controller.offsetY;
				drag.maxScrollY = controller.maxScrollY;
				drag.travel = travel;
			}
		});
		thumb.on(UiEventKind.PointerMove, function(event) {
			dragState.value.lastPointerY = event.y;
			var travel = Math.max(0.0, track.layout.style.height.value -
				thumb.layout.style.height.value);
			if (!dragState.value.dragging || travel <= 0.0)
				return;
			controller.jumpTo(controller.offsetX, dragState.value.offsetY +
				(event.y - dragState.value.pointerY) * controller.maxScrollY / travel);
			event.preventDefault();
		});
		var finishDrag = function(event:UiEvent) {
			if (!dragState.value.dragging)
				return;
			dragState.value.dragging = false;
			visibility.setDragging(false);
			dragState.update(dragState.value);
			event.releasePointer();
			event.preventDefault();
		};
		thumb.on(UiEventKind.PointerUp, finishDrag);
		thumb.on(UiEventKind.PointerCancel, finishDrag);
		thumb.on(UiEventKind.AccessibilityIncrement, function(event) {
			if (controller.scrollBy(0.0, Math.max(40.0, controller.viewportHeight * 0.1)))
				event.preventDefault();
		});
		thumb.on(UiEventKind.AccessibilityDecrement, function(event) {
			if (controller.scrollBy(0.0, -Math.max(40.0, controller.viewportHeight * 0.1)))
				event.preventDefault();
		});
		track.on(UiEventKind.PointerDown, function(event) {
			if (event.button != 0 || track.resolved == null)
				return;
			visibility.reveal();
			var thumbHeight = thumb.layout.style.height.value;
			var travel = Math.max(0.0, track.layout.style.height.value - thumbHeight);
			var geometry:ResolvedLayoutItem = cast track.resolved;
			var local = geometry.viewportToLayout(event.x, event.y);
			var pointerY = local.y - geometry.y;
			var requestedThumbY = Math.max(0.0,
				Math.min(travel, pointerY - thumbHeight * 0.5));
			controller.jumpTo(controller.offsetX, travel <= 0.0 ? 0.0 :
				requestedThumbY / travel * controller.maxScrollY);
			event.preventDefault();
		});
		track.add(thumb);
		viewport.add(track);
		return track;
	}

	function updateVerticalScrollbar(track:RenderNode, width:Float):Bool {
		var thumb = track.children[0];
		var trackStyle = track.layout.style;
		var thumbStyle = thumb.layout.style;
		var inset = 2.0;
		var trackHeight = Math.max(0.0, controller.viewportHeight - inset * 2.0);
		var thumbHeight = controller.contentHeight <= 0.0 ? 0.0 : Math.max(24.0,
			trackHeight * controller.viewportHeight / controller.contentHeight);
		thumbHeight = Math.min(thumbHeight, trackHeight);
		var travel = Math.max(0.0, trackHeight - thumbHeight);
		var thumbY = controller.maxScrollY <= 0.0 ? 0.0 :
			controller.offsetY / controller.maxScrollY * travel;
		var visible = controller.maxScrollY > 0.0 && controller.viewportHeight > 0.0;
		var trackX = Math.max(0.0, width - 12.0);
		var changed = trackStyle.positionX != trackX ||
			trackStyle.height.value != trackHeight || thumbStyle.height.value != thumbHeight ||
			thumbStyle.positionY != thumbY || trackStyle.visible != visible;
		trackStyle.positionX = trackX;
		trackStyle.height = LayoutAxis.fixed(trackHeight);
		trackStyle.visible = visible;
		thumbStyle.height = LayoutAxis.fixed(thumbHeight);
		thumbStyle.positionY = thumbY;
		thumbStyle.visible = visible;
		thumb.focusable = visible;
		var semantics:Semantics = cast thumb.semantics;
		semantics.numericMaximum = controller.maxScrollY;
		semantics.numericValue = controller.offsetY;
		return changed;
	}
}

private class ScrollbarDragState {
	public var dragging:Bool = false;
	public var pointerY:Float = 0.0;
	public var lastPointerY:Float = 0.0;
	public var offsetY:Float = 0.0;
	public var maxScrollY:Float = 0.0;
	public var travel:Float = 0.0;
	public function new() {}
}
