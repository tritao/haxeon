import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.style.ComputedStyle.StyleImpact;
import haxeon.ui.style.StyleState;

/** The UI's own Flags types start empty; the group's other fixtures check they reject raw Int conversions. */
function main():Int {
	if (UiModifier.empty().rawValue() != 0 || UiDirtyFlag.empty().rawValue() != 0) return 1;
	if (StyleImpact.empty().rawValue() != 0 || StyleState.empty().rawValue() != 0) return 2;
	return 42;
}
