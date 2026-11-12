package haxeon.ui.core;

import haxeon.ui.LayoutStyle;

/** Live text keeps its submitted-value bookkeeping when it is also a component's body root. */
class ScopeTextRootNode extends LiveTextNode {
  var owner:RenderScope;

  public function new(id:WidgetId, style:LayoutStyle, value:String, owner:RenderScope) {
    super(id, style, value);
    this.owner = owner;
  }

  override public function scopeOwner():Null<RenderScope> return owner;
  override public function setScopeOwner(owner:RenderScope):Void this.owner = owner;
}
