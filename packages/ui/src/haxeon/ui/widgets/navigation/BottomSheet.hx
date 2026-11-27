package haxeon.ui.widgets.navigation;
import haxeon.ui.core.ViewRoot;

import haxeon.reactive.Signal;
import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.animation.AnimationController;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.Semantics;

/** Slide and drag state of one sheet, kept across rebuilds; the sheet's scope reruns when a signal changes. */
private class SheetMotion {
	public final progress = new Signal<Float>(0.0);
	public var started:Bool = false;
	public final dragY = new Signal<Float>(0.0);
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

	/** Identifies the sheet among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The title over its content. */
	public final title:String;

	/** What the sheet shows. */
	public final content:View;

	/** Called when the user dismisses the sheet; the caller removes it. */
	public final onDismiss:Void->Void;

	/** The sheet's box. */
	public final style:LayoutStyle;

	/** A sheet titled `title` showing `content`. Throws when `key` is empty or there is no content. */
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

	public function buildBody(context:BuildContext):ViewRoot {
		var id = context.rootId("bottom-sheet");
		var motion = context.lazyState(context.id("sheet-motion"), function() return new SheetMotion()).value;
		return buildSheet(context, id, motion);
	}

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	function dismiss():Void {
		if (onDismiss != null) onDismiss();
	}

	function buildSheet(context:BuildContext, id:WidgetId, motion:SheetMotion):RenderNode {
		if (!motion.started) {
			motion.started = true;
			motion.animation = new AnimationController(context.animations, function(value:Float) {
				motion.progress.value = value;
			});
			motion.animation.play(0.0, 1.0, NavUi.slideSeconds, Easing.EaseOut);
		}
		var progress = motion.progress.value;
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
		panelStyle.transform = Transform2D.translation(0.0, (1.0 - progress) * maxHeight + motion.dragY.value);
		var panel = NavUi.child(context, "panel", "bottom-sheet-panel", panelStyle);

		panel.add(buildHeader(context, motion));
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
	function buildHeader(context:BuildContext, motion:SheetMotion):RenderNode {
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
			motion.dragY.value = Math.max(0.0, event.y - motion.dragStartY);
		});
		var finish = function(event:UiEvent) {
			if (!motion.dragging) return;
			motion.dragging = false;
			var far = motion.dragY.value >= DismissDrag;
			motion.dragY.value = 0.0;
			if (far) dismiss();
		};
		header.on(UiEventKind.PointerUp, finish);
		header.on(UiEventKind.PointerCancel, function(event:UiEvent) {
			motion.dragging = false;
			motion.dragY.value = 0.0;
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
