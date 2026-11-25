package haxeon.ui.widgets;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A view placed in a parent under a stable sibling key. */
class KeyedView {
	/** The view's key among its siblings. */
	public final key:Key;

	/** The view placed. */
	public final view:View;

	/** `view` under the key `key`. Throws when `key` is empty or there is no view. */
	public function new(key:String, view:View) {
		if (view == null)
			throw "A keyed view requires a view";
		this.key = new Key(key);
		this.view = view;
	}

	/** Builds the view under its key. */
	public function build(context:BuildContext):RenderNode
		return context.withScope(key, function() return view.build(context));
}
