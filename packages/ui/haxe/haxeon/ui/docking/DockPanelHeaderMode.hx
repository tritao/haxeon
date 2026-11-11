package haxeon.ui.docking;

/** Header ownership for a panel occupying a dock group by itself. */
enum DockPanelHeaderMode implements Hashable {
	Dock;
	/** Panel content provides its own header; multi-panel groups retain dock tabs. */
	Content;
}
