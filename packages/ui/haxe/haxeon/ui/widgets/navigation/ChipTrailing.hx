package haxeon.ui.widgets.navigation;

/** What a Chip shows after its label. */
enum ChipTrailing {
	None;
	Chevron;
	Clear(onClear:Void->Void);
}
