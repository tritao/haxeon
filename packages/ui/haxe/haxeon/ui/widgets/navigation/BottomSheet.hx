package haxeon.ui.widgets.navigation;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.animation.AnimationController;
import haxeon.ui.component.ScopeView;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;

/** Slide and drag state of one sheet, kept across rebuilds. */
private class SheetMotion {
	public var progress:Float = 0.0;
	public var started:Bool = false;
	public var dragY:Float = 0.0;
	public var dragStartY:Float = 0.0;
	public var dragging:Bool = false;
	public var animation:Null<AnimationController> = null;

	public function new() {}
}

/**
 * Slides up from the bottom over a scrim; drag the handle down or tap the scrim (or press Escape) to dismiss. It is an
 * overlay like Dialog, so place it last among the siblings it covers; the caller removes it in `onDismiss`.
 */
class BottomSheet implements ScopeView {
	static inline var MaxHeightFraction:Float = 0.85;
	static inline var DismissDrag:Float = 80.0;

	public final key:String;
	public final title:String;
	public final content:View;
	public final onDismiss:Void->Void;
	public final style:LayoutStyle;

	public function new(key:String, title:String, content:View, onDismiss:Void->Void, ?style:LayoutStyle) {
		if (key == null || key.length == 0 || content == null) throw "Bottom sheets require a stable key and content";
		this.key = key;
		this.title = title == null ? "" : title;
		this.content = content;
		this.onDismiss = onDismiss;
		this.style = style == null ? new LayoutStyle() : style.copy();
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		// The content view is rebuilt with its caller's state.
		return false;
	}

	public function buildBody(context:BuildContext):RenderNode {
		var id = context.rootId("bottom-sheet");
		var motion = context.lazyState(context.id("sheet-motion"), function() return new SheetMotion()).value;
		return context.selfUpdating(id, function() return buildSheet(context, id, motion), false);
	}

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	function dismiss():Void {
		if (onDismiss != null) onDismiss();
	}

	function buildSheet(context:BuildContext, id:WidgetId, motion:SheetMotion):RenderNode {
		if (!motion.started) {
			motion.started = true;
			motion.animation = new AnimationController(context.animations, function(value:Float) {
				motion.progress = value;
				context.requestPatch(id);
			});
			motion.animation.play(0.0, 1.0, NavUi.slideSeconds, Easing.EaseOut);
		}
		var progress = motion.progress;
		var maxHeight = context.viewportHeight * MaxHeightFraction;

		var rootStyle = style.copy();
		rootStyle.width = LayoutAxis.grow();
		rootStyle.height = LayoutAxis.grow();
		rootStyle.positioning = LayoutPositioning.Absolute;
		rootStyle.overlay = true;
		var root = NavUi.box(context, id, "bottom-sheet", key, rootStyle, ["bottom-sheet"]);
		root.focusTrap = true;
		root.hitTestSelf = false;
		var semantics = new Semantics(AccessibilityRole.Dialog, title);
		semantics.states |= AccessibilityState.Modal;
		semantics.actions |= AccessibilityAction.Dismiss;
		root.semantics = semantics;
		root.on(UiEventKind.KeyDown, function(event:UiEvent) {
			if (event.key == UiKey.Escape) {
				event.preventDefault();
				dismiss();
			}
		});

		var scrimStyle = new LayoutStyle();
		scrimStyle.width = LayoutAxis.grow();
		scrimStyle.height = LayoutAxis.grow();
		scrimStyle.positioning = LayoutPositioning.Absolute;
		scrimStyle.background = Color.rgba(0.0, 0.0, 0.0, 0.4 * progress);
		var scrim = NavUi.child(context, "scrim", "bottom-sheet-scrim", scrimStyle);
		var scrimSemantics = new Semantics(AccessibilityRole.Button, "Dismiss");
		scrimSemantics.actions = AccessibilityAction.Activate;
		scrim.semantics = scrimSemantics;
		scrim.on(UiEventKind.Click, function(event:UiEvent) {
			dismiss();
			event.stopPropagation();
		});
		root.add(scrim);

		var holderStyle = new LayoutStyle();
		holderStyle.width = LayoutAxis.grow();
		holderStyle.height = LayoutAxis.grow();
		holderStyle.positioning = LayoutPositioning.Absolute;
		holderStyle.zIndex = 1;
		holderStyle.direction = LayoutDirection.TopToBottom;
		holderStyle.childDistribution = LayoutDistribution.End;
		var holder = NavUi.child(context, "holder", "bottom-sheet-holder", holderStyle);
		holder.hitTestSelf = false;

		var panelStyle = new LayoutStyle();
		panelStyle.width = LayoutAxis.grow();
		panelStyle.height = LayoutAxis.fit(0.0, maxHeight);
		panelStyle.direction = LayoutDirection.TopToBottom;
		panelStyle.background = NavUi.surface;
		panelStyle.radiusTopLeft = 16.0;
		panelStyle.radiusTopRight = 16.0;
		panelStyle.clipVertical = true;
		panelStyle.clipHorizontal = true;
		panelStyle.transform = Transform2D.translation(0.0, (1.0 - progress) * maxHeight + motion.dragY);
		var panel = NavUi.child(context, "panel", "bottom-sheet-panel", panelStyle);

		panel.add(buildHeader(context, id, motion));
		if (title.length > 0) {
			var titleRow = new LayoutStyle();
			titleRow.width = LayoutAxis.grow();
			titleRow.padding = new Insets(16.0, 0.0, 16.0, 10.0);
			var row = NavUi.child(context, "title-row", "bottom-sheet-title", titleRow);
			var heading = NavUi.label(context, "title", title, 17.0, NavUi.text);
			heading.semantics = new Semantics(AccessibilityRole.Heading, title);
			row.add(heading);
			panel.add(row);
		}
		var body = context.withStyleParent(panel.computedStyle,
			function() return context.withScope(new Key("content"), function() return content.build(context)));
		panel.add(body);
		holder.add(panel);
		root.add(holder);
		return root;
	}

	/** The grab handle; dragging it down past a threshold dismisses the sheet. */
	function buildHeader(context:BuildContext, id:WidgetId, motion:SheetMotion):RenderNode {
		var headerStyle = new LayoutStyle();
		headerStyle.width = LayoutAxis.grow();
		headerStyle.height = LayoutAxis.fixed(24.0);
		headerStyle.direction = LayoutDirection.TopToBottom;
		headerStyle.childAlignX = LayoutAlignmentX.Center;
		headerStyle.childDistribution = LayoutDistribution.Center;
		var header = NavUi.child(context, "handle-area", "bottom-sheet-handle-area", headerStyle);
		// First in the sheet's focus trap, so opening a sheet focuses the handle, not a search field: a touch device would
		// otherwise raise its keyboard over the sheet. Tab still reaches the field.
		header.focusable = true;
		header.on(UiEventKind.PointerDown, function(event:UiEvent) {
			motion.dragging = true;
			motion.dragStartY = event.y;
			event.capturePointer();
		});
		header.on(UiEventKind.PointerMove, function(event:UiEvent) {
			if (!motion.dragging) return;
			motion.dragY = Math.max(0.0, event.y - motion.dragStartY);
			context.requestPatch(id);
		});
		var finish = function(event:UiEvent) {
			if (!motion.dragging) return;
			motion.dragging = false;
			var far = motion.dragY >= DismissDrag;
			motion.dragY = 0.0;
			if (far) dismiss();
			else context.requestPatch(id);
		};
		header.on(UiEventKind.PointerUp, finish);
		header.on(UiEventKind.PointerCancel, function(event:UiEvent) {
			motion.dragging = false;
			motion.dragY = 0.0;
			context.requestPatch(id);
		});
		var barStyle = new LayoutStyle();
		barStyle.width = LayoutAxis.fixed(36.0);
		barStyle.height = LayoutAxis.fixed(4.0);
		barStyle.background = NavUi.rgb(0xd0d3da);
		barStyle.radiusTopLeft = 2.0;
		barStyle.radiusTopRight = 2.0;
		barStyle.radiusBottomLeft = 2.0;
		barStyle.radiusBottomRight = 2.0;
		header.add(NavUi.child(context, "bar", "bottom-sheet-handle", barStyle));
		return header;
	}
}
