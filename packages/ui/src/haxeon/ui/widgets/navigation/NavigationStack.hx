package haxeon.ui.widgets.navigation;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.animation.AnimationController;
import haxeon.ui.component.ScopeView;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.Semantics;

import haxeon.ui.widgets.navigation.NavigationController;
/**
 * A stack of screens; the top one is shown full size. Pushes slide the new screen in from the right and pops slide the
 * old one out (220 ms). Back is `NavigationController.handleBack`.
 */
class NavigationStack implements ScopeView {
	public final key:String;
	public final controller:NavigationController;
	public final style:LayoutStyle;

	public function new(key:String, controller:NavigationController, ?style:LayoutStyle) {
		if (key == null || key.length == 0 || controller == null)
			throw "Navigation stacks require a stable key and a controller";
		this.key = key;
		this.controller = controller;
		this.style = style == null ? new LayoutStyle() : style.copy();
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		// Screens come from callbacks that may read application state, so the stack is rebuilt with its parent.
		return false;
	}

	public function buildBody(context:BuildContext):RenderNode {
		var id = context.rootId("navigation-stack");
		return context.selfUpdating(id, function() return buildStack(context, id), false);
	}

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	function buildStack(context:BuildContext, id:WidgetId):RenderNode {
		startTransition(context, id);
		var rootStyle = style.copy();
		rootStyle.width = LayoutAxis.grow();
		rootStyle.height = LayoutAxis.grow();
		rootStyle.clipHorizontal = true;
		rootStyle.clipVertical = true;
		rootStyle.background = context.theme.tokens.surface;
		var root = NavUi.box(context, id, "navigation-stack", key, rootStyle, ["navigation-stack"]);
		root.semantics = new Semantics(AccessibilityRole.Group, "Screens");

		var from = controller.transitionFrom;
		var kind = controller.transitionKind;
		var width = context.viewportWidth;
		if (kind == 0 || from == null || width <= 0.0) {
			root.add(layer(context, controller.top, 0.0, false));
			return root;
		}
		var progress = controller.transitionProgress;
		if (kind > 0) {
			root.add(layer(context, from, 0.0, true));
			root.add(layer(context, controller.top, (1.0 - progress) * width, true));
		} else {
			root.add(layer(context, controller.top, 0.0, true));
			root.add(layer(context, from, progress * width, true));
		}
		return root;
	}

	/** Starts the slide for a revision the first time the stack sees it. */
	function startTransition(context:BuildContext, id:WidgetId):Void {
		if (controller.transitionKind == 0 || controller.startedRevision == controller.revision) return;
		controller.startedRevision = controller.revision;
		if (controller.motion != null) controller.motion.stop();
		var owner = controller;
		var motion = new AnimationController(context.animations, function(value:Float) {
			owner.transitionProgress = value;
			context.requestPatch(id);
		}, function() {
			owner.endTransition();
			context.requestPatch(id);
		});
		owner.motion = motion;
		owner.transitionProgress = 0.0;
		motion.play(0.0, 1.0, NavUi.slideSeconds, Easing.EaseOut);
	}

	function layer(context:BuildContext, entry:NavigationEntry, offsetX:Float, sliding:Bool):RenderNode {
		return context.withScope(new Key("entry:" + entry.id), function() {
			var layerStyle = new LayoutStyle();
			layerStyle.width = LayoutAxis.grow();
			layerStyle.height = LayoutAxis.stretch();
			layerStyle.background = context.theme.tokens.surface;
			layerStyle.clipHorizontal = true;
			layerStyle.clipVertical = true;
			if (sliding) {
				layerStyle.positioning = LayoutPositioning.Absolute;
				layerStyle.transform = Transform2D.translation(offsetX, 0.0);
			}
			var node = NavUi.box(context, context.rootId("navigation-entry"), "navigation-entry", entry.id, layerStyle,
				["navigation-entry"]);
			var content = context.withStyleParent(node.computedStyle,
				function() return context.withScope(new Key("content"),
				function() return entry.build().build(context)));
			node.add(content);
			return node;
		});
	}
}
