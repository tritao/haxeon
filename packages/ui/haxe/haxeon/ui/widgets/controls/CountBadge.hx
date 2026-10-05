package haxeon.ui.widgets.controls;

import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutVisualKind;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.Text;

/** Compact, decorative count inside the containing control's accessible label. */
class CountBadge implements View {
	final count:Int;
	public function new(count:Int) this.count = count;
	public function build(context:BuildContext):RenderNode {
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
		var node = new RenderNode(context.id("count-badge"), LayoutVisualKind.Box, style);
		node.setStyleIdentity("count-badge", "count-badge");
		node.add(new Text(Std.string(count), null, context.theme.tokens.textPrimary, TextStyleOverride.text(11)).build(context));
		node.walk(function(child) child.hitTestSelf = false);
		return node;
	}
}
