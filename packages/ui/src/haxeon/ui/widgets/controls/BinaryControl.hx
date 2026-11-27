package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

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
	public final accessibilityLabel:Null<String>;
	/** Whether the control is on. Activation flips it and then calls `onChange` with the new value. */
	// Activation writes it on the mounted instance, which a later build reads (`readChecked`); descriptions as values
	// replace this with the view's own state.
	public var checked(default, null):Bool;

	/** Checkbox aggregate state; activation clears it and toggles checked. */
	// Activation writes it on the mounted instance, which a later build reads (`readChecked`); descriptions as values
	// replace this with the view's own state.
	public var indeterminate(default, null):Bool;
	/** Whether the control reacts to input; true unless set otherwise. */
	public final enabled:Bool;

	/** Called with the new value after the user turns the control on or off. */
	public final onChange:Null<Bool->Void>;
	final toggle:Bool;
	final style:LayoutStyle;

	/**
	 * A control labelled `label`, shown as a switch when `toggle` and as a checkbox otherwise; `Checkbox` and `Toggle` pick
	 * one. Its row is 32 pixels high unless `style` sets a height. Throws when `key` is empty.
	 */
	public function new(key:String, label:String, checked:Bool, toggle:Bool, ?onChange:Bool->Void, ?style:LayoutStyle,
			?accessibilityLabel:String, indeterminate:Bool = false, enabled:Bool = true) {
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
		this.accessibilityLabel = accessibilityLabel;
		this.indeterminate = indeterminate;
		this.enabled = enabled;
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, BinaryControl)) return false;
		var other:BinaryControl = cast previous;
		return key == other.key && label == other.label && accessibilityLabel == other.accessibilityLabel
			&& checked == other.checked && indeterminate == other.indeterminate && enabled == other.enabled
			&& (onChange == null) == (other.onChange == null) && toggle == other.toggle
			&& haxeon.Diff.mask(style, other.style) == 0;
	}

	public function build(context:BuildContext):ViewRoot {
		var root = context.mountComponent(this);
		// The enclosing scope reads the live control's `checked` too, so activation reruns it: callers commonly keep the
		// flag in a plain field and branch on it, as in a "show advanced" switch, and that read is not tracked. An equal
		// description keeps the mounted instance, which is the one activation writes.
		if (onChange != null) {
			var live:Null<BinaryControl> = cast context.mountedComponent(root);
			(live == null ? this : live).readChecked();
		}
		return root;
	}

	function readChecked():Bool return checked;

	public function buildBody(context:BuildContext):ViewRoot return buildControl(context,
		context.rootId(toggle ? "toggle" : "checkbox"));

	function buildControl(context:BuildContext,
			nodeId:haxeon.ui.core.WidgetId):RenderNode {
		// The indicator and its thumb take the control's states.
		var authored = StyleState.empty();
		if (checked) authored |= StyleState.Checked;
		if (!enabled) authored |= StyleState.Disabled;
		var identity = new StyleIdentity(toggle ? "toggle" : "checkbox", key, key, null,
			[toggle ? "toggle" : "checkbox"]);
		var computed = context.resolveStyled(nodeId, identity, style, authored);
		var node = context.createNode(nodeId, LayoutVisualKind.Box, computed.toLayoutStyle());
		context.applyStyled(node, identity, computed, authored);
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
		// The indicator resolves as its target always did, without the control's tag.
		var indicatorIdentity = new StyleIdentity(toggle ? "toggle-indicator" : "checkbox-indicator",
			key + ":indicator");
		var indicatorComputed = context.resolveStyled(nodeId, indicatorIdentity, indicatorStyle, authored, null, false);
		var indicator = context.createNode(context.rootId("indicator"),
			toggle ? LayoutVisualKind.Box : LayoutVisualKind.Custom,
			indicatorComputed.toLayoutStyle());
		context.applyStyled(indicator, indicatorIdentity, indicatorComputed, authored, nodeId);
		if (toggle) {
			var thumbStyle = new LayoutStyle();
			thumbStyle.width = LayoutAxis.fixed(15.0);
			thumbStyle.height = LayoutAxis.fixed(15.0);
			thumbStyle.radiusTopLeft = thumbStyle.radiusTopRight = 7.5;
			thumbStyle.radiusBottomLeft = thumbStyle.radiusBottomRight = 7.5;
			var thumbIdentity = new StyleIdentity("toggle-thumb", key + ":thumb", null, null, ["toggle"]);
			var thumbComputed = context.resolveStyled(nodeId, thumbIdentity, thumbStyle, authored, null, false);
			var thumb = context.createNode(context.rootId("thumb"), LayoutVisualKind.Box,
				thumbComputed.toLayoutStyle());
			context.applyStyled(thumb, thumbIdentity, thumbComputed, authored, nodeId);
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

		var latest = context.latestOf(this);
		var activate = function(event:UiEvent) {
			if (!enabled) return;
			indeterminate = false;
			checked = !checked;
			semantics.value = checked ? "true" : "false";
			if (checked) semantics.states |= AccessibilityState.Checked;
			else semantics.states = semantics.states.remove(AccessibilityState.Checked);
			var handler = latest().onChange;
			if (handler != null) handler(checked);
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
