package haxeon.ui.widgets.controls;

/** Semantic visual variants backed by theme-generated button state rules. */
enum ButtonVariant implements Hashable {
	/** The main action of a view, in the accent color: one per group of buttons. */
	Primary;

	/** A quiet item in a list of places, such as a sidebar entry or a title bar control; `selected` marks the current one. */
	Navigation;

	/** Any other action: the default. */
	Secondary;
}
