package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.LayoutNode;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.Text;

/** Compact, decorative count inside the containing control's accessible label. */
class CountBadge implements View {
	final count:Int;
	/** A badge showing `count`, for a control whose own accessible label already says it. */
	public function new(count:Int) this.count = count;
	public function build(context:BuildContext):ViewRoot {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fit(22);
		style.height = LayoutAxis.fixed(18);
		style.direction = LayoutDirection.LeftToRight;
		style.childDistribution = LayoutDistribution.Center;
		style.padding = new Insets(6, 0, 6, 0);
		style.childAlignX = LayoutAlignmentX.Center;
		style.childAlignY = LayoutAlignmentY.Center;
		style.background = context.theme.tokens.surfaceHover;
		style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = 9;
		var node = context.createNode(context.rootId("count-badge"), LayoutVisualKind.Box, style);
		node.setStyleIdentity(new StyleIdentity("count-badge", "count-badge"));
		node.add(new Text(Std.string(count),
			null,
			context.theme.tokens.textPrimary,
			new TextStyleOverride(null, 11, null, haxeon.ui.TextStyle.TextWrap.None)).build(context));
		node.walk(child -> child.hitTestSelf = false);
		return node;
	}
}
