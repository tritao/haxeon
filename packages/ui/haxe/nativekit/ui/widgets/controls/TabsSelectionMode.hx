package nativekit.ui.widgets.controls;

/** Ownership of the active tab selection. */
enum TabsSelectionMode {
	/** The Tabs widget retains selection between rebuilt views. */
	Local;
	/** The caller's selectedKey is authoritative on every build. */
	Controlled;
}
