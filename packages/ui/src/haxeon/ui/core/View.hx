package haxeon.ui.core;

/** Ephemeral description rebuilt to produce a render tree each frame. */
interface View {
	/**
	 * Describes this view as a render node, in `context`'s frame. A view keeps no state between builds: everything it shows
	 * comes from its own inputs and from `context`.
	 */
	function build(context:BuildContext):ViewRoot;
}
