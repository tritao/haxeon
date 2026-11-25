package haxeon.ui.component;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A component is its structural description; its native owner runs this body directly. */
interface ScopeView extends View {
	/** Identifies this component among its siblings: its state lives as long as each build gives it the same key. */
	function scopeKey():String;

	/** Whether `previous`, the description this one replaces, has the same inputs, so its body would build the same. */
	function inputsEqual(previous:ScopeView):Bool;

	/** Builds the component's content inside its own scope, which `BuildContext.mountComponent` opens for it. */
	function buildBody(context:BuildContext):RenderNode;
}
