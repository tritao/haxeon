package nativekit.ui.docking;

/** Target region used when docking one panel relative to another. */
enum DockDropZone {
	Center;
	/** Inserts the dragged panel before the target tab in the same group. */
	TabBefore;
	/** Inserts the dragged panel after the target tab in the same group. */
	TabAfter;
	Left;
	Right;
	Top;
	Bottom;
}
