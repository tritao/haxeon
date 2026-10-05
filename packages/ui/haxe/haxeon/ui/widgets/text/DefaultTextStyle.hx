package haxeon.ui.widgets.text;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Applies sparse typography to a subtree while preserving outer inheritance. */
class DefaultTextStyle implements View {
	public final child:View;
	public final style:TextStyleOverride;

	public function new(child:View, style:TextStyleOverride) {
		if (child == null || style == null)
			throw "Default text styles require a child and style";
		this.child = child;
		this.style = style;
	}

	public function build(context:BuildContext):RenderNode
		return context.withTextStyle(style, function() return child.build(context));
}
