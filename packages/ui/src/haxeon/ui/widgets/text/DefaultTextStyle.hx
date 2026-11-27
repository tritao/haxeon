package haxeon.ui.widgets.text;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;

/** Applies sparse typography to a subtree while preserving outer inheritance. */
class DefaultTextStyle implements View {
	/** What the style applies to. */
	public final child:View;

	/** The changes to the inherited text style. */
	public final style:TextStyleOverride;

	/** Applies `style` to the text `child` builds, over what it inherits. */
	public function new(child:View, style:TextStyleOverride) {
		if (child == null || style == null)
			throw "Default text styles require a child and style";
		this.child = child;
		this.style = style;
	}

	public function build(context:BuildContext):ViewRoot
		return context.withTextStyle(style, function() return child.build(context));
}
