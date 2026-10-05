package nativekit.ui.widgets.controls;

/** Semantic visual variants backed by theme-generated button state rules. */
enum abstract ButtonVariant(Int) from Int to Int {
	var Primary = 0;
	var Navigation = 1;
	var Secondary = 2;
}
