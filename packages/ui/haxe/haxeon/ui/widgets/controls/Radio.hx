package haxeon.ui.widgets.controls;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.theme.TextRole;

/** Selectable radio option; use RadioGroup for exclusive selection and arrow keys. */
class Radio implements View {
  final key:Key;
  public final label:String;
  public final value:String;
  public var selected:Bool;
  public var enabled:Bool;
  public final style:LayoutStyle;
  public var onSelect:String -> Void;
  public var hasSelectHandler(default, null):Bool;

  public function new(
    key:String,
    label:String,
    value:String,
    selected:Bool = false,
    ?onSelect:String -> Void,
    ?style:LayoutStyle,
    enabled:Bool = true
  ) {
    if (value == null || value.length == 0) throw "Radio value must be non-empty";
    this.key = new Key(key);
    this.label = label == null ? "" : label;
    this.value = value;
    this.selected = selected;
    this.enabled = enabled;
    this.style = style == null ? defaultStyle() : style.copy();
    hasSelectHandler = onSelect != null;
    this.onSelect = onSelect == null ? function(_) {
    }
    :onSelect;
  }

  public function build(context:BuildContext):RenderNode {
    return context.withScope(key, function() {
      var nodeId = context.rootId("radio");
      // Hover and press change only how the option looks, so it updates itself and the panel around it stays cached.
      return context.selfUpdating(nodeId, function() return buildRadio(context, nodeId));
    }
    );
  }

  function buildRadio(context:BuildContext, nodeId:haxeon.ui.core.WidgetId):RenderNode {
    var flags = context.interactionStates.get(nodeId);
    flags = (selected ? flags.insert(StyleState.Selected) : flags.remove(StyleState.Selected));
    flags = (!enabled ? flags.insert(StyleState.Disabled) : flags.remove(StyleState.Disabled));
    var computed = context.styleResolver.resolve(
      new StyleTarget("radio", key.rawValue(), key.rawValue(), null, ["radio"], flags),
      context.inheritedStyle,
      context.theme.styles,
      context.styleSheet,
      style,
      context.environment
    );
    var node = context.createNode(nodeId, LayoutVisualKind.Box, computed.toLayoutStyle());
    node.setStyleIdentity("radio", key.rawValue(), key.rawValue(), null, ["radio"]);
    node.states = flags;
    node.computedStyle = computed;
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
    var indicatorComputed = context.styleResolver.resolve(
      new StyleTarget("radio-indicator", key.rawValue() + ":indicator", null, null, ["radio"], flags),
      null,
      context.theme.styles,
      context.styleSheet,
      indicatorStyle,
      context.environment
    );
    var indicator = context.createNode(
      context.rootId("indicator"),
      LayoutVisualKind.Box,
      indicatorComputed.toLayoutStyle()
    );
    indicator.setStyleIdentity("radio-indicator", key.rawValue() + ":indicator", null, null, ["radio"]);
    indicator.states = flags;
    indicator.computedStyle = indicatorComputed;
    var dotStyle = new LayoutStyle();
    dotStyle.width = LayoutAxis.fixed(12.0);
    dotStyle.height = LayoutAxis.fixed(12.0);
    dotStyle.radiusTopLeft = dotStyle.radiusTopRight = 6.0;
    dotStyle.radiusBottomLeft = dotStyle.radiusBottomRight = 6.0;
    dotStyle.childAlignX = LayoutAlignmentX.Center;
    dotStyle.childAlignY = LayoutAlignmentY.Center;
    dotStyle.childDistribution = LayoutDistribution.Center;
    var dotComputed = context.styleResolver.resolve(
      new StyleTarget("radio-dot", key.rawValue() + ":dot", null, null, ["radio"], flags),
      null,
      context.theme.styles,
      context.styleSheet,
      dotStyle,
      context.environment
    );
    var dot = context.createNode(context.rootId("dot"), LayoutVisualKind.Box, dotComputed.toLayoutStyle());
    dot.setStyleIdentity("radio-dot", key.rawValue() + ":dot", null, null, ["radio"]);
    dot.states = flags;
    dot.computedStyle = dotComputed;
    var markStyle = new LayoutStyle();
    markStyle.width = LayoutAxis.fixed(6.0);
    markStyle.height = LayoutAxis.fixed(6.0);
    markStyle.radiusTopLeft = markStyle.radiusTopRight = 3.0;
    markStyle.radiusBottomLeft = markStyle.radiusBottomRight = 3.0;
    var markComputed = context.styleResolver.resolve(
      new StyleTarget("radio-mark", key.rawValue() + ":mark", null, null, ["radio"], flags),
      null,
      context.theme.styles,
      context.styleSheet,
      markStyle,
      context.environment
    );
    var mark = context.createNode(context.rootId("mark"), LayoutVisualKind.Box, markComputed.toLayoutStyle());
    mark.setStyleIdentity("radio-mark", key.rawValue() + ":mark", null, null, ["radio"]);
    mark.states = flags;
    mark.computedStyle = markComputed;
    dot.add(mark);
    indicator.add(dot);
    node.add(indicator);

    var text = context.createNode(context.rootId("label"), LayoutVisualKind.Text);
    text.layout.text = label;
    text.applyTextStyle(context.resolveTextRole(TextRole.Label).withTextColor(context.theme.textRoleColor(
      TextRole.Label,
      enabled
    )));
    var fontSource = computed.source(StyleProperty.FontSize);
    var letterSource = computed.source(StyleProperty.LetterSpacing);
    if (fontSource != null && fontSource.layer != "framework") text.layout.textStyle =
      text.layout.textStyle.withFontSize(computed.getNumber(StyleProperty.FontSize));
    if (letterSource != null && letterSource.layer != "framework") text.layout.textStyle =
      text.layout.textStyle.withLetterSpacing(computed.getNumber(StyleProperty.LetterSpacing));
    node.add(text);
    if (enabled && hasSelectHandler) {
      var select = function(_:UiEvent) {
        onSelect(value);
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
