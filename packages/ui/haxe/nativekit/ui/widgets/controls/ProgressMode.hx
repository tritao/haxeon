package nativekit.ui.widgets.controls;

/** Visual and semantic behavior of a progress indicator. */
enum abstract ProgressMode(Int) from Int to Int {
	var Determinate = 0;
	var Indeterminate = 1;
}
