package haxeon.ui.widgets.navigation;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.component.ScopeView;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;

/** A transient message bar with an optional action. The caller decides when to show and hide it. */
class Snackbar implements ScopeView {
	public final key:String;
	public final text:String;
	public final actionLabel:Null<String>;
	public final onAction:Null<Void->Void>;
	public final style:LayoutStyle;

	public function new(key:String, text:String, ?actionLabel:String, ?onAction:Void->Void, ?style:LayoutStyle) {
		if (key == null || key.length == 0 || text == null) throw "Snackbars require a stable key and text";
		this.key = key;
		this.text = text;
		this.actionLabel = actionLabel;
		this.onAction = onAction;
		this.style = style == null ? new LayoutStyle() : style.copy();
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, Snackbar)) return false;
		var other:Snackbar = cast previous;
		return key == other.key && text == other.text && actionLabel == other.actionLabel && onAction == other.onAction
			&& haxeon.Diff.mask(style, other.style) == 0;
	}

	public function buildBody(context:BuildContext):RenderNode return buildBar(context, context.rootId("snackbar"));

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	function buildBar(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		var rootStyle = style.copy();
		rootStyle.direction = LayoutDirection.LeftToRight;
		rootStyle.childAlignY = LayoutAlignmentY.Center;
		rootStyle.padding = new Insets(16.0, 0.0, 8.0, 0.0);
		rootStyle.height = LayoutAxis.fixed(48.0);
		rootStyle.childGap = 12.0;
		rootStyle.background = NavUi.text;
		rootStyle.radiusTopLeft = 8.0;
		rootStyle.radiusTopRight = 8.0;
		rootStyle.radiusBottomLeft = 8.0;
		rootStyle.radiusBottomRight = 8.0;
		var node = NavUi.box(context, id, "snackbar", key, rootStyle, ["snackbar"]);
		node.semantics = new Semantics(AccessibilityRole.Group, text);
		var message = NavUi.label(context, "text", text, 14.0, NavUi.white);
		message.layout.style.width = LayoutAxis.grow();
		node.add(message);
		if (actionLabel != null && actionLabel.length > 0) {
			var actionStyle = new LayoutStyle();
			actionStyle.height = LayoutAxis.fixed(NavUi.touchTarget);
			actionStyle.padding = new Insets(12.0, 0.0, 12.0, 0.0);
			actionStyle.childAlignY = LayoutAlignmentY.Center;
			actionStyle.direction = LayoutDirection.LeftToRight;
			var action = context.withScope(new Key("action"), function() {
				var button = NavUi.box(context, context.rootId("snackbar-action"), "snackbar-action", "action",
					actionStyle, ["snackbar-action"]);
				button.focusable = true;
				button.enabled = true;
				var buttonSemantics = new Semantics(AccessibilityRole.Button, actionLabel);
				buttonSemantics.actions = AccessibilityAction.Activate;
				button.semantics = buttonSemantics;
				var action = onAction;
				if (action != null) button.onActivate(function(_:UiEvent) action());
				button.add(NavUi.label(context, "label", actionLabel, 14.0, NavUi.rgb(0x9db4ff)));
				return button;
			});
			node.add(action);
		}
		return node;
	}
}
