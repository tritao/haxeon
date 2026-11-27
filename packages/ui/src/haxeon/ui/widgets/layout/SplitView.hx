package haxeon.ui.widgets.layout;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.semantics.Semantics;

/**
	Two-pane composition with a controlled, draggable leading or trailing
	pane. The caller owns persistence, routing, and responsive collapse policy.
*/
class SplitView implements View {
	final key:Key;
	final leading:View;
	final trailing:View;

	/** Whether the panes are side by side or stacked. */
	public final orientation:SplitOrientation;

	/** Which pane has the set extent; the other takes the rest. */
	public final resizableSide:SplitSide;

	/** The smallest extent the user can drag it to. */
	public final minimumExtent:Float;

	/** The largest extent the user can drag it to. */
	public final maximumExtent:Float;

	/** The divider's draggable thickness, in logical pixels. */
	public final dividerExtent:Float;

	/** The divider's drawn thickness. */
	public final dividerVisualExtent:Float;
	final dividerHairline:Bool;

	/** Called with the new extent as the user drags the divider. */
	public final onResize:Null<Float->Void>;

	/** Called when the user collapses or restores the resizable pane. */
	public final onCollapsedChanged:Null<Bool->Void>;

	/** The split's box. */
	public final style:LayoutStyle;

	/** The divider's box. */
	public final dividerStyle:LayoutStyle;

	/**
	 * The resizable pane's extent, in logical pixels: on every build when `onResize` is given, which is then told of each
	 * change (controlled); otherwise the starting extent, which the view keeps as the user drags (local).
	 */
	public final extent:Float;

	/**
	 * Whether the resizable pane is collapsed: on every build when `onCollapsedChanged` is given; otherwise at the start,
	 * and the view expands it when the user drags it open.
	 */
	public final collapsed:Bool;

	/**
	 * Two panes, `leading` and `trailing`, split by a draggable divider; the rest is given by name
	 * (`new SplitView("split", list, detail, extent: width, onResize: next -> width = next)`). Throws when a pane is
	 * missing or the extents are invalid.
	 */
	public function new(key:String, leading:View, trailing:View,
			orientation:SplitOrientation = SplitOrientation.Horizontal,
			resizableSide:SplitSide = SplitSide.Trailing, extent:Float = 280.0, minimumExtent:Float = 160.0,
			maximumExtent:Float = 480.0, collapsed:Bool = false, dividerExtent:Float = 8.0, ?dividerVisualExtent:Float,
			dividerHairline:Bool = false, ?style:LayoutStyle, ?dividerStyle:LayoutStyle, ?onResize:Float->Void,
			?onCollapsedChanged:Bool->Void) {
		if (leading == null || trailing == null) throw "SplitView requires leading and trailing views";
		if (!finite(extent)
			|| !finite(minimumExtent) || !finite(maximumExtent) || !finite(dividerExtent)
			|| minimumExtent < 0.0 || maximumExtent < minimumExtent
			|| dividerExtent < 0.0
			|| (dividerVisualExtent != null
			&& (!finite(dividerVisualExtent) || dividerVisualExtent < 0.0 || dividerVisualExtent > dividerExtent)))
			throw "SplitView extent policy is invalid";
		this.key = new Key(key);
		this.leading = leading;
		this.trailing = trailing;
		this.orientation = orientation;
		this.resizableSide = resizableSide;
		this.minimumExtent = minimumExtent;
		this.maximumExtent = maximumExtent;
		this.dividerExtent = dividerExtent;
		this.dividerVisualExtent = dividerVisualExtent == null ? dividerExtent : dividerVisualExtent;
		this.dividerHairline = dividerHairline;
		this.extent = clamp(extent, minimumExtent, maximumExtent);
		this.collapsed = collapsed;
		this.onResize = onResize;
		this.onCollapsedChanged = onCollapsedChanged;
		this.style = style == null ? defaultStyle() : style.copy();
		this.dividerStyle = dividerStyle == null ? defaultDividerStyle() : dividerStyle.copy();
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, function() {
			var horizontal = orientation == SplitOrientation.Horizontal;
			var rootStyle = style.copy();
			rootStyle.direction = horizontal ? LayoutDirection.LeftToRight : LayoutDirection.TopToBottom;
			rootStyle.childGap = 0.0;
			rootStyle.childDistribution = LayoutDistribution.Start;
			rootStyle.wrapMode = LayoutWrapMode.NoWrap;
			var root = context.createNode(context.rootId("split-view"), LayoutVisualKind.Box, rootStyle);
			// A controlled input is authoritative on every build; a local one is the view's own state.
			var localExtent:State<Float> = context.state(context.id("extent"), extent),
				localCollapsed:State<Bool> = context.state(context.id("collapsed"), collapsed);
			var pane = context.lazyState(context.id("pane"), () -> new SplitPane()).value;
			pane.extent = bounded(onResize != null ? extent : localExtent.value);
			pane.collapsed = onCollapsedChanged != null ? collapsed : localCollapsed.value;
			pane.localExtent = localExtent;
			pane.localCollapsed = localCollapsed;
			var collapsed = pane.collapsed;
			var paneExtent = collapsed ? 0.0 : pane.extent;

			var leadingPane = context.createNode(context.rootId("leading-pane"),
				LayoutVisualKind.Box,
				paneStyle(horizontal, resizableSide == SplitSide.Leading, paneExtent));
			leadingPane.layout.style.visible = !collapsed || resizableSide != SplitSide.Leading;
			var leadingNode = context.withScope(new Key("leading"), function() {
				return leading.build(context);
			});
			leadingPane.add(paneContent(context, "leading-content", leadingNode));
			root.add(leadingPane);

			if (dividerExtent > 0.0) {
				var dividerId = context.id("divider");
				var dividerIdentity = new StyleIdentity("split-divider", key.rawValue, key.rawValue + ":divider", null,
					["split-divider"]);
				var dividerComputed = context.resolveStyled(dividerId, dividerIdentity, dividerLayoutStyle(horizontal));
				var divider = context.createNode(dividerId, LayoutVisualKind.Box, dividerComputed.toLayoutStyle());
				context.applyStyled(divider, dividerIdentity, dividerComputed);
				if (dividerHairline) {
					var color = divider.layout.style.background;
					divider.layout.style.background = Color.rgba(0, 0, 0, 0);
					var lineStyle = new LayoutStyle();
					lineStyle.width = horizontal ? LayoutAxis.fixed(dividerExtent) : LayoutAxis.stretch();
					lineStyle.height = horizontal ? LayoutAxis.stretch() : LayoutAxis.fixed(dividerExtent);
					var line = context.createNode(context.rootId("divider-visual"), LayoutVisualKind.Custom, lineStyle);
					line.hitTestSelf = false;
					line.cachePolicy = haxeon.ui.core.RenderNode.CachePolicy.None;
					line.onPaint(function(canvas, geometry) {
						var density = context.environment.pixelDensity;
						var transform = geometry.transform;
						var scale = (horizontal ? transform.a : transform.d) * density;
						if (scale == 0) return;
						var center = horizontal ? geometry.width / 2 : geometry.height / 2;
						var device = (horizontal ? transform.transformedX(geometry.x + center,
							geometry.y) : transform.transformedY(geometry.x,
							geometry.y + center)) * density;
						var start = center + (Math.round(device) - device) / scale;
						var thickness = 1.0 / Math.abs(scale);
						// The border primitive uses a solid device mesh, avoiding path-fill
						// antialias fringes. A tiny outset survives float conversion before
						// its inward pixel snap; the resulting narrow rectangle is one pixel.
						var epsilon = thickness * 0.001;
						canvas.drawRectBorder(horizontal ? new haxeon.ui.Rect(start - epsilon,
							0, thickness + 2 * epsilon, geometry.height) : new haxeon.ui.Rect(0,
							start - epsilon,
							geometry.width,
							thickness + 2 * epsilon),
							0,
							color);
					});
					divider.add(line);
				} else if (dividerVisualExtent < dividerExtent) {
					var visualStyle = new LayoutStyle();
					visualStyle.width = horizontal ? LayoutAxis.fixed(dividerVisualExtent) : LayoutAxis.grow();
					visualStyle.height = horizontal ? LayoutAxis.grow() : LayoutAxis.fixed(dividerVisualExtent);
					visualStyle.background = divider.layout.style.background;
					divider.layout.style.background = Color.rgba(0.0, 0.0, 0.0, 0.0);
					divider.layout.style.childAlignX = LayoutAlignmentX.Center;
					divider.layout.style.childAlignY = LayoutAlignmentY.Center;
					// Main-axis centering uses distribution; alignment centers the cross axis.
					divider.layout.style.childDistribution = LayoutDistribution.Center;
					var visual = context.createNode(context.rootId("divider-visual"), LayoutVisualKind.Box,
						visualStyle);
					visual.hitTestSelf = false;
					divider.add(visual);
				}
				divider.focusable = true;
				divider.cursor = horizontal ? CursorShape.HorizontalResize : CursorShape.VerticalResize;
				var sideName = resizableSide == SplitSide.Leading ? "Leading" : "Trailing";
				var dividerSemantics = new Semantics(AccessibilityRole.Separator, '$sideName pane divider');
				dividerSemantics.actions = AccessibilityAction.Increment | AccessibilityAction.Decrement;
				dividerSemantics.numericValue = pane.extent;
				dividerSemantics.numericMinimum = minimumExtent;
				dividerSemantics.numericMaximum = maximumExtent;
				divider.semantics = dividerSemantics;
				var dragState:State<SplitDragState> = context.state(divider.id, new SplitDragState());
				installDividerHandlers(divider, horizontal, dragState, pane);
				if (dividerHairline) {
					// A zero-sized flow anchor marks the shared pane edge. Only the
					// absolute hit target overlaps the panes; no resize gutter is reserved.
					var anchorStyle = new LayoutStyle();
					anchorStyle.width = horizontal ? LayoutAxis.percent(0) : LayoutAxis.grow();
					anchorStyle.height = horizontal ? LayoutAxis.grow() : LayoutAxis.percent(0);
					var anchor = context.createNode(context.rootId("divider-anchor"), LayoutVisualKind.Box,
						anchorStyle);
					anchor.hitTestSelf = false;
					divider.layout.style.positioning = haxeon.ui.LayoutStyle.LayoutPositioning.Absolute;
					divider.layout.style.positionX = horizontal ? -dividerExtent / 2 : 0;
					divider.layout.style.positionY = horizontal ? 0 : -dividerExtent / 2;
					divider.layout.style.zIndex = 1;
					divider.layout.style.clipToParent = false;
					anchor.add(divider);
					root.add(anchor);
				} else root.add(divider);
			}

			var trailingPane = context.createNode(context.rootId("trailing-pane"),
				LayoutVisualKind.Box,
				paneStyle(horizontal, resizableSide == SplitSide.Trailing, paneExtent));
			trailingPane.layout.style.visible = !collapsed || resizableSide != SplitSide.Trailing;
			var trailingNode = context.withScope(new Key("trailing"), function() {
				return trailing.build(context);
			});
			trailingPane.add(paneContent(context, "trailing-content", trailingNode));
			root.add(trailingPane);
			return root;
		});
	}

	function installDividerHandlers(divider:RenderNode, horizontal:Bool, dragState:State<SplitDragState>,
			pane:SplitPane):Void {
		divider.on(UiEventKind.PointerDown, function(event:UiEvent) {
			if (event.button != 0) return;
			var drag = dragState.value;
			event.capturePointer();
			drag.dragging = true;
			drag.startPointer = horizontal ? event.x : event.y;
			drag.startExtent = pane.collapsed ? minimumExtent : pane.extent;
			dragState.update(drag);
			event.preventDefault();
		});
		divider.on(UiEventKind.PointerMove, function(event:UiEvent) {
			var drag = dragState.value;
			if (!drag.dragging) return;
			var pointer = horizontal ? event.x : event.y;
			var delta = pointer - drag.startPointer;
			var direction = resizableSide == SplitSide.Leading ? 1.0 : -1.0;
			updateExtent(pane, drag.startExtent + delta * direction, true);
			event.preventDefault();
		});
		var handleKey = function(event:UiEvent) {
			var delta = 0.0;
			var positive = horizontal ? (resizableSide
				== SplitSide.Leading ? UiKey.Right : UiKey.Left)
				: (resizableSide == SplitSide.Leading ? UiKey.Down : UiKey.Up);
			var negative = horizontal ? (resizableSide
				== SplitSide.Leading ? UiKey.Left : UiKey.Right)
				: (resizableSide == SplitSide.Leading ? UiKey.Up : UiKey.Down);
			if (event.key == positive) delta = keyboardStep();
			else if (event.key == negative) delta = -keyboardStep();
			else if (event.key == UiKey.Home) updateExtent(pane, minimumExtent, true);
			else if (event.key == UiKey.End) updateExtent(pane, maximumExtent, true);
			else return;
			if (delta != 0.0) updateExtent(pane, pane.extent + delta, true);
			event.preventDefault();
		};
		divider.on(UiEventKind.KeyDown, handleKey);
		divider.on(UiEventKind.KeyRepeat, handleKey);
		divider.on(UiEventKind.AccessibilityIncrement, function(event) {
			updateExtent(pane, pane.extent + keyboardStep() * actionGranularity(event), true);
		});
		divider.on(UiEventKind.AccessibilityDecrement, function(event) {
			updateExtent(pane, pane.extent - keyboardStep() * actionGranularity(event), true);
		});
		divider.on(UiEventKind.PointerUp, function(_) {
			var drag = dragState.value;
			drag.dragging = false;
			dragState.update(drag);
		});
		divider.on(UiEventKind.PointerCancel, function(_) {
			var drag = dragState.value;
			drag.dragging = false;
			dragState.update(drag);
		});
	}

	/** Moves the pane to `next`, telling the caller of a controlled input and keeping a local one. */
	function updateExtent(pane:SplitPane, next:Float, expandCollapsed:Bool):Bool {
		if (!finite(next)) return false;
		var target = bounded(next);
		var changed = target != pane.extent;
		pane.extent = target;
		if (pane.collapsed && expandCollapsed && target > 0.0) {
			pane.collapsed = false;
			if (onCollapsedChanged != null) onCollapsedChanged(false);
			else pane.localCollapsed.update(false);
		}
		if (changed) {
			if (onResize != null) onResize(target);
			else pane.localExtent.update(target);
		}
		return changed;
	}

	static inline function keyboardStep():Float return 8.0;

	static function actionGranularity(event:UiEvent):Int {
		var action:AccessibilityActionData = cast event.data;
		return action != null && action.granularity > 1 ? action.granularity : 1;
	}

	/** Keep nested floating content in its pane's layer, below the resize chrome. */
	function paneContent(context:BuildContext, key:String, content:ViewRoot):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.positioning = haxeon.ui.LayoutStyle.LayoutPositioning.Absolute;
		style.clipToParent = true;
		var root = context.createNode(context.rootId(key), LayoutVisualKind.Box, style);
		root.hitTestSelf = false;
		root.add(content);
		return root;
	}

	function paneStyle(horizontal:Bool, resizable:Bool, paneExtent:Float):LayoutStyle {
		var result = new LayoutStyle();
		if (horizontal) {
			result.width = resizable ? extentAxis(paneExtent) : LayoutAxis.grow();
			result.height = LayoutAxis.grow();
		} else {
			result.width = LayoutAxis.grow();
			result.height = resizable ? extentAxis(paneExtent) : LayoutAxis.grow();
		}
		return result;
	}

	static function extentAxis(paneExtent:Float):LayoutAxis {
		// Clay's fixed-size representation treats zero as an open upper bound.
		// Percent zero is the unambiguous collapsed extent.
		return paneExtent <= 0.0 ? LayoutAxis.percent(0.0) : LayoutAxis.fixed(paneExtent);
	}

	function bounded(value:Float):Float {
		if (!finite(value)) return minimumExtent;
		return clamp(value, minimumExtent, maximumExtent);
	}

	function dividerLayoutStyle(horizontal:Bool):LayoutStyle {
		var result = dividerStyle.copy();
		if (horizontal) {
			result.width = LayoutAxis.fixed(dividerExtent);
			result.height = LayoutAxis.grow();
		} else {
			result.width = LayoutAxis.grow();
			result.height = LayoutAxis.fixed(dividerExtent);
		}
		return result;
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.grow();
		return result;
	}

	static function defaultDividerStyle():LayoutStyle {
		return new LayoutStyle();
	}

	static inline function clamp(value:Float,
			minimum:Float, maximum:Float):Float return value < minimum ? minimum : value > maximum ? maximum : value;

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;
}

/** Pointer-drag state that survives the frame-local view rebuild. */
private class SplitDragState {
	public var dragging:Bool;
	public var startPointer:Float;
	public var startExtent:Float;

	public function new() {
		dragging = false;
		startPointer = 0.0;
		startExtent = 0.0;
	}
}

/**
 * The pane's current extent and collapse, which the divider's handlers read and change between builds, and the local
 * state a build reads when the caller does not control them.
 */
private class SplitPane {
	public var extent:Float = 0.0;
	public var collapsed:Bool = false;
	public var localExtent:Null<State<Float>> = null;
	public var localCollapsed:Null<State<Bool>> = null;

	public function new() {}
}

/** Main axis used by a SplitView. */
enum SplitOrientation implements Hashable {
	/** Panes side by side, divided by a vertical bar. */
	Horizontal;
	/** Panes one above the other, divided by a horizontal bar. */
	Vertical;
}

/** Which edge contains a SplitView's resizable pane. */
enum SplitSide implements Hashable {
	/** The first pane (left or top) has the set extent; the second takes the rest. */
	Leading;
	/** The second pane (right or bottom) has the set extent; the first takes the rest. */
	Trailing;
}
