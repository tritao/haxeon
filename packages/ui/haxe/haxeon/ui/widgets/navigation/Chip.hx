package haxeon.ui.widgets.navigation;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutStyle;
import haxeon.ui.component.ScopeView;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.Icon;

/** Pill chip: label, optional trailing chevron or clear (x); `active` uses the dark fill. */
class Chip implements ScopeView {
	public final key:String;
	public final label:String;
	public final onClick:Void->Void;
	public final active:Bool;
	public final trailing:ChipTrailing;
	public final style:LayoutStyle;

	public function new(key:String, label:String, onClick:Void->Void, active:Bool = false,
			trailing:ChipTrailing = None, ?style:LayoutStyle) {
		if (key == null || key.length == 0 || label == null) throw "Chips require a stable key and a label";
		this.key = key;
		this.label = label;
		this.onClick = onClick;
		this.active = active;
		this.trailing = trailing == null ? ChipTrailing.None : trailing;
		this.style = style == null ? new LayoutStyle() : style.copy();
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, Chip)) return false;
		var other:Chip = cast previous;
		return key == other.key && label == other.label && onClick == other.onClick && active == other.active
			&& sameTrailing(trailing, other.trailing) && haxeon.Diff.mask(style, other.style) == 0;
	}

	static function sameTrailing(a:ChipTrailing, b:ChipTrailing):Bool {
		return switch [a, b] {
			case [None, None]: true;
			case [Chevron, Chevron]: true;
			case [Clear(x), Clear(y)]: x == y;
			default: false;
		};
	}

	public function buildBody(context:BuildContext):RenderNode return buildChip(context, context.rootId("chip"));

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	function buildChip(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		var rootStyle = style.copy();
		rootStyle.direction = LayoutDirection.LeftToRight;
		rootStyle.childAlignY = LayoutAlignmentY.Center;
		rootStyle.childDistribution = LayoutDistribution.Center;
		rootStyle.height = LayoutAxis.fixed(36.0);
		rootStyle.padding = new Insets(14.0, 0.0, 14.0, 0.0);
		rootStyle.childGap = 6.0;
		rootStyle.background = active ? NavUi.chipActiveFill : NavUi.chipFill;
		rootStyle.radiusTopLeft = 18.0;
		rootStyle.radiusTopRight = 18.0;
		rootStyle.radiusBottomLeft = 18.0;
		rootStyle.radiusBottomRight = 18.0;
		var node = NavUi.box(context, id, "chip", key, rootStyle, ["chip"]);
		node.focusable = true;
		node.enabled = true;
		var semantics = new Semantics(AccessibilityRole.Button, label);
		semantics.actions = AccessibilityAction.Activate;
		if (active) semantics.states |= AccessibilityState.Selected;
		node.semantics = semantics;
		if (onClick != null) node.onActivate(function(_:UiEvent) onClick());

		var foreground = active ? NavUi.white : NavUi.text;
		node.add(NavUi.label(context, "label", label, 14.0, foreground));
		switch trailing {
			case None:
			case Chevron:
				node.add(context.withScope(new Key("trailing"),
					function() return new Icon("chevron", IconName.ChevronDown, 14.0, foreground).build(context)));
			case Clear(onClear):
				var clearStyle = new LayoutStyle();
				clearStyle.width = LayoutAxis.fixed(24.0);
				clearStyle.height = LayoutAxis.fixed(24.0);
				clearStyle.childAlignX = LayoutAlignmentX.Center;
				clearStyle.childAlignY = LayoutAlignmentY.Center;
				clearStyle.childDistribution = LayoutDistribution.Center;
				var clear = context.withScope(new Key("clear"), function() {
					var clearNode = NavUi.box(context, context.rootId("chip-clear"), "chip-clear", "clear", clearStyle,
						["chip-clear"]);
					clearNode.focusable = true;
					clearNode.enabled = true;
					var clearSemantics = new Semantics(AccessibilityRole.Button, "Clear " + label);
					clearSemantics.actions = AccessibilityAction.Activate;
					clearNode.semantics = clearSemantics;
					clearNode.onActivate(function(event:UiEvent) {
						event.stopPropagation();
						if (onClear != null) onClear();
					});
					clearNode.add(new Icon("x", IconName.Close, 12.0, foreground).build(context));
					return clearNode;
				});
				node.add(clear);
		}
		return node;
	}
}

/** What a Chip shows after its label. */
enum ChipTrailing {
	None;
	Chevron;
	Clear(onClear:Void->Void);
}
