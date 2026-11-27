package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.widgets.Icon;

/** Accessible icon-only button with a required non-visual label. */
class IconButton implements ScopeView {
	/** Identifies the button among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The icon shown. */
	public final icon:IconName;

	/** The button's accessible name, which assistive technology reads and a tooltip may show: required. */
	public final label:String;

	/** The button's box. */
	public final style:LayoutStyle;

	/** Whether the button reacts to input. */
	public final enabled:Bool;

	/** Called when the button is activated by a click, a tap, or the keyboard. */
	public final onClick:Void->Void;

	/** A button showing `icon` and named `label`. Throws when `key` or `label` is empty. */
	public function new(key:String,
			icon:IconName,
			label:String,
			?onClick:Void->Void,
			?style:LayoutStyle,
			enabled:Bool = true) {
		if (key == null || key.length == 0
			|| label == null || label.length == 0) throw "Icon buttons require a stable key and accessible label";
		this.key = key;
		this.icon = icon;
		this.label = label;
		this.onClick = onClick;
		this.style = style == null ? new LayoutStyle() : style.copy();
		this.enabled = enabled;
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, IconButton)) return false;
		var other:IconButton = cast previous;
		return key == other.key && haxeon.Equality.equals(icon, other.icon) && label == other.label
			&& haxeon.Diff.mask(style,
			other.style) == 0 && enabled == other.enabled && (onClick == null) == (other.onClick == null);
	}

	public function buildBody(context:BuildContext):ViewRoot return buildButton(context,
		context.rootId("icon-button"));

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	function buildButton(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		var flags = context.styleStates(id, "button", key, key, ["icon-button"], ["button", "icon-button"]);
		flags = !enabled ? flags.insert(StyleState.Disabled) : flags.remove(StyleState.Disabled);
		var computed = context.resolveStyle(new StyleTarget("button", key, key, ["icon-button"], [
			"button",
			"icon-button"
		], flags),
			style);
		var node = context.createNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
		node.setStyleIdentity("button", key, key, ["icon-button"], ["button", "icon-button"]);
		node.states = flags;
		node.computedStyle = computed;
		node.focusable = enabled;
		node.enabled = enabled;
		var semantics = new Semantics(AccessibilityRole.Button, label);
		semantics.actions = AccessibilityAction.Activate;
		if (!enabled) semantics.states |= AccessibilityState.Disabled;
		node.semantics = semantics;
		if (enabled && onClick != null) {
			var latest = context.latestOf(this);
			var activate = function(_:UiEvent) {
				var handler = latest().onClick;
				if (handler != null) handler();
			};
			node.onActivate(activate);
		}
		var foreground = context.theme.buttonLabelColor(enabled, node.layout.style.background);
		node.add(new Icon("glyph", icon, 16.0, foreground).build(context));
		return node;
	}
}
