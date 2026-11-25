package haxeon.ui.core;

/** Position of the current delivery in a routed event. Direct notifications use Target. */
enum UiEventPhase {
	/** Going down from the root to the target: an ancestor sees the event before the widget does. */
	Capture;

	/** At the target itself. */
	Target;

	/** Coming back up from the target to the root. */
	Bubble;
}
