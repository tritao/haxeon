package haxeon.ui.widgets.controls;

import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleStateUtil;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.widgets.Icon;

/** Accessible icon-only button with a required non-visual label. */
class IconButton implements View {
	public final key:String;
	public final icon:IconName;
	public final label:String;
	public final style:LayoutStyle;
	public var enabled:Bool;
	public var onClick:Void->Void;

	public function new(key:String, icon:IconName, label:String,
			?onClick:Void->Void, ?style:LayoutStyle) {
		if (key == null || key.length == 0 || label == null || label.length == 0)
			throw "Icon buttons require a stable key and accessible label";
		this.key = key;
		this.icon = icon;
		this.label = label;
		this.onClick = onClick;
		this.style = style == null ? new LayoutStyle() : style.copy();
		enabled = true;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var id = context.id("icon-button");
			var flags = StyleStateUtil.withState(context.interactionStates.get(id),
				StyleState.Disabled, !enabled);
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
				node.on(UiEventKind.Click, activate);
				node.on(UiEventKind.Activate, activate);
			}
			var foreground = context.theme.buttonLabelColor(enabled,
				node.layout.style.background);
			node.add(new Icon("glyph", icon, 16.0, foreground).build(context));
			return node;
		});
	}
}
