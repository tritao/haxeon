package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.UiEvent;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleState;
import haxeon.ui.theme.TextRole;

/** Selectable radio option; use RadioGroup for exclusive selection and arrow keys. */
class Radio implements ScopeView {
	final key:Key;
	/** The text beside the button, and its accessible name. */
	public final label:String;

	/** What choosing this button selects: never empty. */
	public final value:String;

	/** Whether this is the chosen button of its group. */
	public final selected:Bool;

	/** Whether the button reacts to input. */
	public final enabled:Bool;

	/** The button's row. */
	public final style:LayoutStyle;

	/** Called with `value` when the user chooses this button. */
	public final onSelect:String->Void;
	var hasSelectHandler:Bool;

	/**
	 * A single radio button; `RadioGroup` lays out a set of them and keeps one chosen. Throws when `value` is empty.
	 */
	public function new(key:String,
			label:String,
			value:String,
			selected:Bool = false,
			?onSelect:String->Void,
			?style:LayoutStyle,
			enabled:Bool = true) {
		if (value == null || value.length == 0) throw "Radio value must be non-empty";
		this.key = new Key(key);
		this.label = label == null ? "" : label;
		this.value = value;
		this.selected = selected;
		this.enabled = enabled;
		this.style = style == null ? defaultStyle() : style.copy();
		hasSelectHandler = onSelect != null;
		this.onSelect = onSelect == null ? _ -> {}
			: onSelect;
	}

	public function scopeKey():String return key.rawValue;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, Radio)) return false;
		var other:Radio = cast previous;
		return key == other.key && label == other.label && value == other.value && selected == other.selected
			&& enabled == other.enabled && hasSelectHandler == other.hasSelectHandler
			&& haxeon.Diff.mask(style, other.style) == 0;
	}

	public function buildBody(context:BuildContext):ViewRoot return buildRadio(context, context.rootId("radio"));

	// Hover and press change only how the option looks: they rerun this scope, and the panel around it stays cached.
	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	function buildRadio(context:BuildContext, nodeId:haxeon.ui.core.WidgetId):RenderNode {
		// The indicator, its dot and its mark take the row's states.
		var authored = StyleState.empty();
		if (selected) authored |= StyleState.Selected;
		if (!enabled) authored |= StyleState.Disabled;
		var identity = new StyleIdentity("radio", key.rawValue, key.rawValue, null, ["radio"]);
		var computed = context.resolveStyled(nodeId, identity, style, authored, null);
		var node = context.createNode(nodeId, LayoutVisualKind.Box, computed.toLayoutStyle());
		context.applyStyled(node, identity, computed, authored);
		node.focusable = enabled;
		node.enabled = enabled;
		var semantics = new Semantics(AccessibilityRole.Radio, label, value);
		semantics.actions = AccessibilityAction.Activate;
		if (selected) semantics.states |= AccessibilityState.Selected;
		node.semantics = semantics;

		var indicatorStyle = new LayoutStyle();
		indicatorStyle.width = LayoutAxis.fixed(18.0);
		indicatorStyle.height = LayoutAxis.fixed(18.0);
		indicatorStyle.radiusTopLeft = indicatorStyle.radiusTopRight = 9.0;
		indicatorStyle.radiusBottomLeft = indicatorStyle.radiusBottomRight = 9.0;
		indicatorStyle.childAlignX = LayoutAlignmentX.Center;
		indicatorStyle.childAlignY = LayoutAlignmentY.Center;
		indicatorStyle.childDistribution = LayoutDistribution.Center;
		var indicatorIdentity = new StyleIdentity("radio-indicator", key.rawValue + ":indicator", null, null,
			["radio"]);
		var indicatorComputed = context.resolveStyled(nodeId, indicatorIdentity, indicatorStyle, authored, null, false);
		var indicator = context.createNode(context.rootId("indicator"),
			LayoutVisualKind.Box,
			indicatorComputed.toLayoutStyle());
		context.applyStyled(indicator, indicatorIdentity, indicatorComputed, authored, nodeId);
		var dotStyle = new LayoutStyle();
		dotStyle.width = LayoutAxis.fixed(12.0);
		dotStyle.height = LayoutAxis.fixed(12.0);
		dotStyle.radiusTopLeft = dotStyle.radiusTopRight = 6.0;
		dotStyle.radiusBottomLeft = dotStyle.radiusBottomRight = 6.0;
		dotStyle.childAlignX = LayoutAlignmentX.Center;
		dotStyle.childAlignY = LayoutAlignmentY.Center;
		dotStyle.childDistribution = LayoutDistribution.Center;
		var dotIdentity = new StyleIdentity("radio-dot", key.rawValue + ":dot", null, null, ["radio"]);
		var dotComputed = context.resolveStyled(nodeId, dotIdentity, dotStyle, authored, null, false);
		var dot = context.createNode(context.rootId("dot"), LayoutVisualKind.Box, dotComputed.toLayoutStyle());
		context.applyStyled(dot, dotIdentity, dotComputed, authored, nodeId);
		var markStyle = new LayoutStyle();
		markStyle.width = LayoutAxis.fixed(6.0);
		markStyle.height = LayoutAxis.fixed(6.0);
		markStyle.radiusTopLeft = markStyle.radiusTopRight = 3.0;
		markStyle.radiusBottomLeft = markStyle.radiusBottomRight = 3.0;
		var markIdentity = new StyleIdentity("radio-mark", key.rawValue + ":mark", null, null, ["radio"]);
		var markComputed = context.resolveStyled(nodeId, markIdentity, markStyle, authored, null, false);
		var mark = context.createNode(context.rootId("mark"), LayoutVisualKind.Box, markComputed.toLayoutStyle());
		context.applyStyled(mark, markIdentity, markComputed, authored, nodeId);
		dot.add(mark);
		indicator.add(dot);
		node.add(indicator);

		var text = context.createNode(context.rootId("label"), LayoutVisualKind.Text);
		text.layout.text = label;
		text.applyTextStyle(context.resolveTextRole(TextRole.Label)
			.withTextColor(context.theme.textRoleColor(TextRole.Label,
			enabled)));
		var fontSource = computed.source(StyleProperty.FontSize);
		var letterSource = computed.source(StyleProperty.LetterSpacing);
		if (fontSource != null && fontSource.layer != "framework") text.layout.textStyle =
			text.layout.textStyle.withFontSize(computed.getNumber(StyleProperty.FontSize));
		if (letterSource != null && letterSource.layer != "framework") text.layout.textStyle =
			text.layout.textStyle.withLetterSpacing(computed.getNumber(StyleProperty.LetterSpacing));
		node.add(text);
		if (enabled && hasSelectHandler) {
			var latest = context.latestOf(this);
			var select = (_:UiEvent) -> {
				latest().onSelect(value);
			};
			node.onActivate(select);
		}
		return node;
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.direction = LayoutDirection.LeftToRight;
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.fixed(32.0);
		result.padding = new Insets(4.0, 5.0, 4.0, 5.0);
		result.childGap = 9.0;
		result.childAlignY = LayoutAlignmentY.Center;
		return result;
	}
}
