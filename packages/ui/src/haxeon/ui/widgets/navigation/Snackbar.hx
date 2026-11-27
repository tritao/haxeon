package haxeon.ui.widgets.navigation;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.semantics.Semantics;

/** A transient message bar with an optional action. The caller decides when to show and hide it. */
class Snackbar implements ScopeView {
	/** Identifies the bar among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The message. */
	public final text:String;

	/** The action button's text; no button when null. */
	public final actionLabel:Null<String>;

	/** Called when the user presses the action. */
	public final onAction:Null<Void->Void>;

	/** The bar's box. */
	public final style:LayoutStyle;

	/** A message bar showing `text`, with an action when `actionLabel` is given. */
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
		return key == other.key && text == other.text && actionLabel == other.actionLabel
			&& (onAction == null) == (other.onAction == null)
			&& haxeon.Diff.mask(style, other.style) == 0;
	}

	public function buildBody(context:BuildContext):ViewRoot return buildBar(context, context.rootId("snackbar"));

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

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
				if (onAction != null) {
					var latest = context.latestOf(this);
					button.onActivate(function(_:UiEvent) {
						var handler = latest().onAction;
						if (handler != null) handler();
					});
				}
				button.add(NavUi.label(context, "label", actionLabel, 14.0, NavUi.rgb(0x9db4ff)));
				return button;
			});
			node.add(action);
		}
		return node;
	}
}
