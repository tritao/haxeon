package haxeon.ui.widgets.controls;

import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.widgets.Icon;

/** Accessible icon-only button with a required non-visual label. */
class IconButton implements View {
	public final key:String;
	public final icon:IconName;
	public final label:String;
	public final style:LayoutStyle;
	public final enabled:Bool;
	public final onClick:Void->Void;

	public function new(key:String, icon:IconName, label:String,
			?onClick:Void->Void, ?style:LayoutStyle, enabled:Bool = true) {
		if (key == null || key.length == 0 || label == null || label.length == 0)
			throw "Icon buttons require a stable key and accessible label";
		this.key = key;
		this.icon = icon;
		this.label = label;
		this.onClick = onClick;
		this.style = style == null ? new LayoutStyle() : style.copy();
		this.enabled = enabled;
	}

	/** The structural body is independent from caller-owned listeners and overlays. */
	public function body():View return new IconButtonBody(this);

	public function build(context:BuildContext):RenderNode
		return new TrackedScope(key, body).build(context);

	function buildButton(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		var flags = context.interactionStates.get(id);
		flags = !enabled ? flags.insert(StyleState.Disabled) : flags.remove(StyleState.Disabled);
		var computed = context.resolveStyle(new StyleTarget("button", key, key,
			["icon-button"], ["button", "icon-button"], flags), style);
		var node = new RenderNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
		node.setStyleIdentity("button", key, key, ["icon-button"],
			["button", "icon-button"]);
		node.states = flags;
		node.computedStyle = computed;
		node.focusable = enabled;
		node.enabled = enabled;
		var semantics = new Semantics(AccessibilityRole.Button, label);
		semantics.actions = AccessibilityAction.Activate;
		if (!enabled)
			semantics.states |= AccessibilityState.Disabled;
		node.semantics = semantics;
		if (enabled && onClick != null) {
			var activate = function(_:UiEvent) {
				onClick();
			};
			node.onActivate(activate);
		}
		var foreground = context.theme.buttonLabelColor(enabled,
			node.layout.style.background);
		node.add(new Icon("glyph", icon, 16.0, foreground).build(context));
		return node;
	}
}

/** Terminal styled control node inside the component's structural scope. */
@:access(haxeon.ui.widgets.controls.IconButton)
private class IconButtonBody implements View {
	final button:IconButton;
	public function new(button:IconButton) this.button = button;
	public function build(context:BuildContext):RenderNode
		return button.buildButton(context, context.id("icon-button"));
}
