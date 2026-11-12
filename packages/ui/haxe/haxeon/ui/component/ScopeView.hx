package haxeon.ui.component;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A component is its structural description; its native owner runs this body directly. */
interface ScopeView extends View {
  function scopeKey():String;
  function inputsEqual(previous:ScopeView):Bool;
  function buildBody(context:BuildContext):RenderNode;
}
