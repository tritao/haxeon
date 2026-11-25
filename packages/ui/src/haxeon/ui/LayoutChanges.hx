package haxeon.ui;

/** Native inputs and child lists invalidated by the retained tree comparison or announced geometry feedback. */
@:noCompletion
class LayoutChanges {
	public final inputs:IntIndex = new IntIndex();
	public final children:IntIndex = new IntIndex();

	public function new() {}

	public function clear():Void {
		inputs.clear();
		children.clear();
	}
}
