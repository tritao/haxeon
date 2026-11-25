package haxeon.ui.style;

/** Typed pseudo-state flags used by style selectors. */
enum abstract StyleState(Int) implements Flags {
	/** The pointer is over the box. */
	var Hovered = 1 << 0;

	/** The box is being pressed. */
	var Pressed = 1 << 1;

	/** The box has keyboard focus. */
	var Focused = 1 << 2;

	/** The box is disabled. */
	var Disabled = 1 << 3;

	/** The box is selected. */
	var Selected = 1 << 4;

	/** The box is checked, as a check box or toggle. */
	var Checked = 1 << 5;
}
