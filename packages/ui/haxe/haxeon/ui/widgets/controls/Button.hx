package haxeon.ui.widgets.controls;
import haxeon.ui.widgets.Icon;

import haxeon.ui.Color;
import haxeon.ui.core.Key;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.theme.TextRole;
import haxeon.ui.style.StyleResolver;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleStateUtil;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;

/** Compositional Haxe button; the native engine sees only box and text nodes. */
class Button implements View {
	public final key:String;
	public final label:String;
	/** Optional full name when compact visible text abbreviates an action. */
	public var accessibilityLabel:Null<String>;
	public final style:LayoutStyle;
	/** Typed selector classes used by composite controls and application styles. */
	public var classes:Array<String>;
	/** Theme-backed visual treatment; defaults to Secondary. Request Primary for the main action. */
	public var variant:ButtonVariant;
	public var enabled:Bool;
	public var selected:Bool;
	/** Optional decorative icons rendered inside the button's single hit target. */
	public var leadingIcon:Null<IconName>;
	/** Custom decorative view inside the same button hit target. */
	public var leadingView:Null<View>;
	public var trailingView:Null<View> = null;
	public var trailingIcon:Null<IconName>;
	public var iconSize:Float;
	/** Semantic role override used by composite controls such as tabs and menus. */
	public var semanticRole:AccessibilityRole;
	/** Action capabilities override used by composite controls. */
	public var semanticActions:Int;
	public var onClick:Void->Void;
	/** Optional event-aware activation, useful for positioning a menu by its trigger. */
	public var onClickEvent:Null<UiEvent->Void>;

	public function new(label:String, ?style:LayoutStyle, ?onClick:Void->Void, ?key:String) {
		this.label = label == null ? "" : label;
		accessibilityLabel = null;
		this.key = key == null || key.length == 0
			? (this.label.length == 0 ? "button" : this.label)
			: key;
		this.style = style == null ? defaultStyle() : style.copy();
		this.style.direction = LayoutDirection.LeftToRight;
		this.style.childAlignY = LayoutAlignmentY.Center;
		if (this.style.childGap == 0.0)
			this.style.childGap = 8.0;
		classes = [];
		variant = ButtonVariant.Secondary;
		this.onClick = onClick;
		onClickEvent = null;
		enabled = true;
		selected = false;
		leadingIcon = null;
		trailingIcon = null;
		iconSize = 16.0;
		semanticRole = AccessibilityRole.Button;
		semanticActions = AccessibilityAction.Activate;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() return buildScoped(context));
	}

	function buildScoped(context:BuildContext):RenderNode {
		var id = context.id("button");
		var flags:Int = context.interactionStates.get(id);
		flags = StyleStateUtil.withState(flags, StyleState.Selected, selected);
		flags = StyleStateUtil.withState(flags, StyleState.Disabled, !enabled);
		var resolvedClasses = classes.copy();
		if (variant == ButtonVariant.Navigation)
			resolvedClasses.push("navigation");
		else if (variant == ButtonVariant.Secondary)
			resolvedClasses.push("secondary");
		var target = new StyleTarget("button", key, key, resolvedClasses, ["button"], flags);
		var computed = context.styleResolver.resolve(target, context.inheritedStyle, context.theme.styles,
			context.styleSheet, style, context.environment);
		var resolvedStyle = computed.toLayoutStyle();
		var node = new RenderNode(id, LayoutVisualKind.Box, resolvedStyle);
		node.setStyleIdentity("button", key, key, resolvedClasses, ["button"]);
		node.states = flags;
		node.computedStyle = computed;
		node.focusable = enabled;
		node.enabled = enabled;
		var semantics = new Semantics(semanticRole,
			accessibilityLabel == null ? label : accessibilityLabel);
		semantics.actions = semanticActions;
		if (selected)
			semantics.states |= AccessibilityState.Selected;
		node.semantics = semantics;
		if (enabled && (onClick != null || onClickEvent != null)) {
			var activate = function(event:UiEvent) {
				if (onClickEvent != null) onClickEvent(event);
				else onClick();
			};
			node.on(UiEventKind.Click, activate);
			node.on(UiEventKind.Activate, activate);
		}
		var foreground = variant == ButtonVariant.Secondary || variant == ButtonVariant.Navigation
			? (enabled ? context.theme.tokens.textPrimary : context.theme.tokens.textDisabled)
			: context.theme.buttonLabelColor(enabled, resolvedStyle.background);
		if (leadingView != null)
			node.add(context.withScope(new Key("leading-view"), function() return leadingView.build(context)));
		else if (leadingIcon != null)
			node.add(new Icon("leading-icon", leadingIcon, iconSize, foreground).build(context));
		if (label.length > 0) {
			var labelNode = context.withScope(new Key("label"), function() {
				var text = new RenderNode(context.id("label"), LayoutVisualKind.Text);
				text.layout.text = label;
				var labelStyle = context.resolveTextRole(TextRole.Button,
					TextStyleOverride.paragraph(TextWrap.None));
				var fontSource = computed.source(StyleProperty.FontSize);
				var letterSource = computed.source(StyleProperty.LetterSpacing);
				labelStyle = labelStyle.merge(new TextStyleOverride(null,
					fontSource != null && fontSource.layer != "framework"
						? computed.get(StyleProperty.FontSize) : null,
					letterSource != null && letterSource.layer != "framework"
						? computed.get(StyleProperty.LetterSpacing) : null));
				labelStyle = labelStyle.withTextColor(foreground);
				text.applyTextStyle(labelStyle);
				return text;
			});
			node.add(labelNode);
		}
		if (trailingView != null)
			node.add(context.withScope(new Key("trailing-view"), function() return trailingView.build(context)));
		else if (trailingIcon != null)
			node.add(new Icon("trailing-icon", trailingIcon, iconSize, foreground).build(context));
		return node;
	}

	static function defaultStyle():LayoutStyle {
		return new LayoutStyle();
	}
}
