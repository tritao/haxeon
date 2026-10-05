package haxeon.ui.docking;

/** Header ownership for a panel occupying a dock group by itself. */
enum abstract DockPanelHeaderMode(Int) {
	var Dock = 0;
	/** Panel content provides its own header; multi-panel groups retain dock tabs. */
	var Content = 1;
}
