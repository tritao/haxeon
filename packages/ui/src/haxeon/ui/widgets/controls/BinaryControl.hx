package haxeon.ui.widgets.controls;

import Observable;

import haxeon.ui.LayoutNode;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.theme.TextRole;

/**
 * Shared Haxe implementation for checkbox and switch-style boolean controls. The caller owns the value: activation flips
 * this instance's observable `checked`, which reruns the control's scope at once, and reports it through `onChange`; a
 * parent that builds again with another value replaces it.
 */
class BinaryControl implements ScopeView implements Observable {
	/** Identifies the control among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The text beside the box or switch, and its accessible name unless `accessibilityLabel` gives one. */
	public final label:String;

	/** Names the control for assistive technology when its visible label is elsewhere, as in a property row. */
	public var accessibilityLabel:Null<String> = null;
	/** Whether the control is on. Activation flips it and then calls `onChange` with the new value. */
	public var checked:Bool;

	/** Checkbox aggregate state; activation clears it and toggles checked. */
	public var indeterminate:Bool = false;
	/** Whether the control reacts to input; true unless set otherwise. */
	public var enabled:Bool;

	/** Called with the new value after the user turns the control on or off. */
	public var onChange:Null<Bool->Void>;
	final toggle:Bool;
	final style:LayoutStyle;

	/**
	 * A control labelled `label`, shown as a switch when `toggle` and as a checkbox otherwise; `Checkbox` and `Toggle` pick
	 * one. Its row is 32 pixels high unless `style` sets a height. Throws when `key` is empty.
	 */
	public function new(key:String, label:String, checked:Bool, toggle:Bool, ?onChange:Bool->Void, ?style:LayoutStyle) {
		if (key == null || key.length == 0) throw "Boolean controls require a stable key";
		this.key = key;
		this.label = label == null ? "" : label;
		this.checked = checked;
		this.toggle = toggle;
		this.onChange = onChange;
		this.style = style == null ? defaultStyle() : style.copy();
		this.style.direction = LayoutDirection.LeftToRight;
		this.style.childAlignY = LayoutAlignmentY.Center;
		this.style.childGap = 9.0;
		if (this.style.height.sizing == LayoutSizing.Fit) this.style.height = LayoutAxis.fixed(32.0);
		this.enabled = true;
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, BinaryControl)) return false;
		var other:BinaryControl = cast previous;
		return key == other.key && label == other.label && accessibilityLabel == other.accessibilityLabel
			&& checked == other.checked && indeterminate == other.indeterminate && enabled == other.enabled
			&& onChange == other.onChange && toggle == other.toggle && haxeon.Diff.mask(style, other.style) == 0;
	}

	public function build(context:BuildContext):RenderNode {
		// The enclosing scope reads `checked` too, so activation reruns it: callers commonly keep the flag in a plain
		// field and branch on it, as in a "show advanced" switch, and that read is not tracked.
		if (onChange != null) readChecked();
		return context.mountComponent(this);
	}

	function readChecked():Bool return checked;

	public function buildBody(context:BuildContext):RenderNode return buildControl(context,
		context.rootId(toggle ? "toggle" : "checkbox"));

	function buildControl(context:BuildContext,
			nodeId:haxeon.ui.core.WidgetId):RenderNode {
		var flags = context.interactionStates.get(nodeId);
		flags = (checked ? flags.insert(StyleState.Checked) : flags.remove(StyleState.Checked));
		flags = (!enabled ? flags.insert(StyleState.Disabled) : flags.remove(StyleState.Disabled));
		var target = new StyleTarget(toggle ? "toggle" : "checkbox",
			key,
			key,
			null,
			[toggle ? "toggle" : "checkbox"],
			flags);
		var computed = context.styleResolver.resolve(target,
			context.inheritedStyle,
			context.theme.styles,
			context.styleSheet,
			style,
			context.environment);
		var node = context.createNode(nodeId, LayoutVisualKind.Box, computed.toLayoutStyle());
		node.setStyleIdentity(toggle ? "toggle" : "checkbox", key, key, null, [toggle ? "toggle" : "checkbox"]);
		node.states = flags;
		// The indicator and its mark take the row's hover and press.
		node.buildsFromHover = true;
		node.computedStyle = computed;
		node.focusable = enabled;
		node.enabled = enabled;
		var semantics = new Semantics(toggle ? AccessibilityRole.Switch : AccessibilityRole.Checkbox,
			accessibilityLabel == null ? label : accessibilityLabel,
			indeterminate ? "mixed" : checked ? "true" : "false");
		semantics.actions = toggle ? AccessibilityAction.Toggle : AccessibilityAction.Activate;
		if (checked) semantics.states |= AccessibilityState.Checked;
		if (!enabled) semantics.states |= AccessibilityState.Disabled;
		node.semantics = semantics;

		var indicatorStyle = new LayoutStyle();
		indicatorStyle.width = LayoutAxis.fixed(toggle ? 34.0 : 19.0);
		indicatorStyle.height = LayoutAxis.fixed(toggle ? 19.0 : 19.0);
		if (!toggle) {
			indicatorStyle.radiusTopLeft = indicatorStyle.radiusTopRight = 4.0;
			indicatorStyle.radiusBottomLeft = indicatorStyle.radiusBottomRight = 4.0;
		} else {
			indicatorStyle.radiusTopLeft = indicatorStyle.radiusTopRight = 10.0;
			indicatorStyle.radiusBottomLeft = indicatorStyle.radiusBottomRight = 10.0;
			indicatorStyle.padding = new Insets(2.0, 2.0, 2.0, 2.0);
			indicatorStyle.childAlignY = LayoutAlignmentY.Center;
		}
		var indicatorTarget = new StyleTarget(toggle ? "toggle-indicator" : "checkbox-indicator",
			key + ":indicator",
			null,
			null,
			null,
			flags);
		var indicatorComputed = context.styleResolver.resolve(indicatorTarget,
			null,
			context.theme.styles,
			context.styleSheet,
			indicatorStyle,
			context.environment);
		var indicator = context.createNode(context.rootId("indicator"),
			toggle ? LayoutVisualKind.Box : LayoutVisualKind.Custom,
			indicatorComputed.toLayoutStyle());
		indicator.setStyleIdentity(toggle ? "toggle-indicator" : "checkbox-indicator",
			key + ":indicator",
			null,
			null,
			[toggle ? "toggle" : "checkbox"]);
		indicator.states = flags;
		indicator.computedStyle = indicatorComputed;
		if (toggle) {
			var thumbStyle = new LayoutStyle();
			thumbStyle.width = LayoutAxis.fixed(15.0);
			thumbStyle.height = LayoutAxis.fixed(15.0);
			thumbStyle.radiusTopLeft = thumbStyle.radiusTopRight = 7.5;
			thumbStyle.radiusBottomLeft = thumbStyle.radiusBottomRight = 7.5;
			var thumbComputed = context.styleResolver.resolve(new StyleTarget("toggle-thumb", key + ":thumb", null,
				null, ["toggle"], flags),
				null,
				context.theme.styles,
				context.styleSheet,
				thumbStyle,
				context.environment);
			var thumb = context.createNode(context.rootId("thumb"), LayoutVisualKind.Box,
				thumbComputed.toLayoutStyle());
			thumb.setStyleIdentity("toggle-thumb", key + ":thumb", null, null, ["toggle"]);
			thumb.states = flags;
			thumb.computedStyle = thumbComputed;
			indicator.add(thumb);
		}
		if (!toggle) {
			indicator.onPaint(function(canvas, _) {
				if (!checked && !indeterminate) return;
				var mark = checked ? Color.rgba(1.0, 1.0, 1.0, 1.0) : context.theme.tokens.textPrimary;
				if (indeterminate) {
					canvas.fillRect(new Rect(4, 8, 11, 3), mark);
					return;
				}
				canvas.withState(function(target) {
					target.translate(5.5, 10.5);
					target.rotate(0.7853981634);
					target.fillRect(new Rect(-2.5, -1.1, 5.0, 2.2), mark);
				});
				canvas.withState(function(target) {
					target.translate(11.0, 8.5);
					target.rotate(-0.7853981634);
					target.fillRect(new Rect(-5.5, -1.1, 11.0, 2.2), mark);
				});
			}, "checked:" + checked + ":mixed:" + indeterminate);
		}
		node.add(indicator);
		var labelNode = context.createNode(context.rootId("label"), LayoutVisualKind.Text);
		labelNode.layout.text = label;
		labelNode.applyTextStyle(context.resolveTextRole(TextRole.Label)
			.withTextColor(context.theme.textRoleColor(TextRole.Label,
			enabled)));
		var fontSource = computed.source(StyleProperty.FontSize);
		var letterSource = computed.source(StyleProperty.LetterSpacing);
		if (fontSource != null && fontSource.layer != "framework") labelNode.layout.textStyle =
			labelNode.layout.textStyle.withFontSize(computed.getNumber(StyleProperty.FontSize));
		if (letterSource != null && letterSource.layer != "framework") labelNode.layout.textStyle =
			labelNode.layout.textStyle.withLetterSpacing(computed.getNumber(StyleProperty.LetterSpacing));
		node.add(labelNode);

		var activate = function(event:UiEvent) {
			if (!enabled) return;
			indeterminate = false;
			checked = !checked;
			semantics.value = checked ? "true" : "false";
			if (checked) semantics.states |= AccessibilityState.Checked;
			else semantics.states = semantics.states.remove(AccessibilityState.Checked);
			if (onChange != null) onChange(checked);
		};
		node.onActivate(activate);
		return node;
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.padding = new Insets(4.0, 5.0, 4.0, 5.0);
		return result;
	}
}
