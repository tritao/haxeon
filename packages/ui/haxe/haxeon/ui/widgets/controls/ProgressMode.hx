package haxeon.ui.widgets.controls;

/** Visual and semantic behavior of a progress indicator. */
enum ProgressMode implements Hashable {
	/** The bar fills to the share of the work done. */
	Determinate;

	/** An animated bar for work whose amount is unknown; with reduced motion it holds still. */
	Indeterminate;
}
