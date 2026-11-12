package haxeon.ui.widgets.controls;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.text.MiddleEllipsisText;

import haxeon.ui.Color;
import haxeon.ui.core.Key;
import haxeon.ui.component.ScopeView;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.theme.TextRole;
import haxeon.ui.style.StyleResolver;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;

/** Compositional Haxe button; the native engine sees only box and text nodes. */
class Button implements ScopeView {
	public final key:String;
	public final label:String;
	/** Optional full name when compact visible text abbreviates an action. */
	public final accessibilityLabel:Null<String>;
	/** Optional label presentation; the button retains its full semantic label. */
	public final labelView:Null<View>;
	/** Fit a single-line label within the button content area. */
	public final ellipsizeLabel:Bool;
	public final style:LayoutStyle;
	/** Typed selector classes used by composite controls and application styles. */
	public final classes:Array<String>;
	/** Theme-backed visual treatment; defaults to Secondary. Request Primary for the main action. */
	public final variant:ButtonVariant;
	public final enabled:Bool;
	public final selected:Bool;
	/** Optional decorative icons rendered inside the button's single hit target. */
	public final leadingIcon:Null<IconName>;
	/** Custom decorative view inside the same button hit target. */
	public final leadingView:Null<View>;
	public final trailingView:Null<View>;
	public final trailingIcon:Null<IconName>;
	public final iconSize:Float;
	final semanticDescription:Semantics;
	final activation:Null<UiEvent->Void>;
	public final onClick:Void->Void;
	/** Optional event-aware activation, useful for positioning a menu by its trigger. */
	public final onClickEvent:Null<UiEvent->Void>;
	/** Selector snapshots are immutable inside the resolver; hover commonly alternates between the same states. */
	var firstTarget:Null<StyleTarget> = null;
	var otherTargets:Null<Array<StyleTarget>> = null;

	public function new(label:String, ?style:LayoutStyle, ?onClick:Void->Void, ?key:String,
			?enabled:Bool, ?variant:ButtonVariant, ?selected:Bool, ?classes:Array<String>,
			?leadingIcon:IconName, ?trailingIcon:IconName, ?leadingView:View, ?trailingView:View,
			?labelView:View, ?ellipsizeLabel:Bool, ?iconSize:Float, ?accessibilityLabel:String,
			?onClickEvent:UiEvent->Void, ?semantics:Semantics) {
		this.label = label == null ? "" : label;
		this.accessibilityLabel = accessibilityLabel;
		this.key = key == null || key.length == 0
			? (this.label.length == 0 ? "button" : this.label)
			: key;
		this.style = style == null ? defaultStyle() : style.copy();
		this.style.direction = LayoutDirection.LeftToRight;
		this.style.childAlignY = LayoutAlignmentY.Center;
		if (this.style.childGap == 0.0) this.style.childGap = 8.0;
		this.classes = classes == null ? [] : classes.copy();
		this.variant = variant == null ? ButtonVariant.Secondary : variant;
		this.onClick = onClick;
		this.onClickEvent = onClickEvent;
		this.enabled = enabled == null ? true : enabled;
		this.selected = selected == true;
		this.labelView = labelView;
		this.ellipsizeLabel = ellipsizeLabel == true;
		this.leadingIcon = leadingIcon;
		this.leadingView = leadingView;
		this.trailingView = trailingView;
		this.trailingIcon = trailingIcon;
		this.iconSize = iconSize == null ? 16.0 : iconSize;
		semanticDescription = semantics == null
			? new Semantics(AccessibilityRole.Button, accessibilityLabel == null ? this.label : accessibilityLabel)
			: semantics;
		if (semantics == null) semanticDescription.actions = AccessibilityAction.Activate;
		if (this.selected) semanticDescription.states |= AccessibilityState.Selected;
		activation = !this.enabled ? null : onClickEvent != null ? onClickEvent : onClick == null ? null : function(_:UiEvent) onClick();
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, Button)) return false;
		var other:Button = cast previous;
		if (classes.length != other.classes.length) return false;
		for (index in 0...classes.length) if (classes[index] != other.classes[index]) return false;
		return label == other.label && key == other.key && accessibilityLabel == other.accessibilityLabel &&
			labelView == other.labelView && ellipsizeLabel == other.ellipsizeLabel &&
			haxeon.Diff.mask(style, other.style) == 0 &&
			variant == other.variant && enabled == other.enabled && selected == other.selected &&
			haxeon.Equality.equals(leadingIcon, other.leadingIcon) && leadingView == other.leadingView &&
			trailingView == other.trailingView && haxeon.Equality.equals(trailingIcon, other.trailingIcon) &&
			iconSize == other.iconSize && Semantics.same(semanticDescription, other.semanticDescription) &&
			onClick == other.onClick && onClickEvent == other.onClickEvent;
	}

	public function buildBody(context:BuildContext):RenderNode
		return buildButton(context, context.rootId("button"));

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	function buildButton(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		var flags:StyleState = context.interactionStates.get(id);
		flags = (selected ? flags.insert(StyleState.Selected) : flags.remove(StyleState.Selected));
		flags = (!enabled ? flags.insert(StyleState.Disabled) : flags.remove(StyleState.Disabled));
		var resolvedClasses = classes.copy();
		if (variant == ButtonVariant.Navigation)
			resolvedClasses.push("navigation");
		else if (variant == ButtonVariant.Secondary)
			resolvedClasses.push("secondary");
		var target = styleTarget(resolvedClasses, flags);
		var computed = context.styleResolver.resolve(target, context.inheritedStyle, context.theme.styles,
			context.styleSheet, style, context.environment);
		var resolvedStyle = computed.toLayoutStyle();
		var node = context.createNode(id, LayoutVisualKind.Box, resolvedStyle);
		node.setStyleIdentityWithOwnedClasses("button", key, key, resolvedClasses, ["button"]);
		node.states = flags;
		node.computedStyle = computed;
		node.focusable = enabled;
		node.enabled = enabled;
		node.semantics = semanticDescription;
		if (enabled && activation != null) node.onActivate(activation);
		var foreground = context.theme.buttonLabelColor(enabled, resolvedStyle.background,
			variant == ButtonVariant.Primary ? context.theme.tokens.textOnAccent : context.theme.tokens.textPrimary);
		if (leadingView != null)
			node.add(context.withScope(new Key("leading-view"), function() return context.withStyleParent(computed, function() return leadingView.build(context))));
		else if (leadingIcon != null)
			node.add(new Icon("leading-icon", leadingIcon, iconSize, foreground).build(context));
		if (labelView != null) {
			node.add(context.withScope(new Key("label"), function() return context.withStyleParent(computed, function() return labelView.build(context))));
		} else if (label.length > 0) {
			var labelNode = context.withScope(new Key("label"), function() {
				var fontSource = computed.source(StyleProperty.FontSize);
				var letterSource = computed.source(StyleProperty.LetterSpacing);
				var labelStyle = context.resolveTextRole(TextRole.Button, new TextStyleOverride(null,
					fontSource != null && fontSource.layer != "framework"
						? computed.getNumber(StyleProperty.FontSize) : null,
					letterSource != null && letterSource.layer != "framework"
						? computed.getNumber(StyleProperty.LetterSpacing) : null,
					TextWrap.None, null, null, null, foreground));
				if (ellipsizeLabel) {
					var typography = labelStyle.textStyle, paragraph = labelStyle.paragraphStyle;
					return new MiddleEllipsisText("fitted-label", label, false,
						new TextStyleOverride(typography.font, typography.fontSize, typography.letterSpacing,
							paragraph.wrap, paragraph.alignment, paragraph.lineHeight, paragraph.direction,
							foreground, paragraph.tabWidth)).build(context);
				}
				var text = context.createNode(context.rootId("label"), LayoutVisualKind.Text);
				text.layout.text = label;
				text.applyTextStyle(labelStyle);
				return text;
			});
			node.add(labelNode);
		}
		if (trailingView != null)
			node.add(context.withScope(new Key("trailing-view"), function() return context.withStyleParent(computed, function() return trailingView.build(context))));
		else if (trailingIcon != null)
			node.add(new Icon("trailing-icon", trailingIcon, iconSize, foreground).build(context));
		return node;
	}

	static function defaultStyle():LayoutStyle {
		return new LayoutStyle();
	}

	function styleTarget(resolvedClasses:Array<String>, flags:StyleState):StyleTarget {
		var first = firstTarget;
		if (first != null && targetMatches(first, resolvedClasses, flags)) return first;
		var others = otherTargets;
		if (others != null)
			for (target in others) if (targetMatches(target, resolvedClasses, flags)) return target;
		var target = new StyleTarget("button", key, key, resolvedClasses, ["button"], flags);
		if (first == null) firstTarget = target;
		else {
			if (others == null) { others = []; otherTargets = others; }
			if (others.length >= 3) others.shift();
			others.push(target);
		}
		return target;
	}

	static function targetMatches(target:StyleTarget, classes:Array<String>, flags:StyleState):Bool {
		if (target.states != flags || target.classes.length != classes.length) return false;
		for (index in 0...classes.length) if (target.classes[index] != classes[index]) return false;
		return true;
	}
}
