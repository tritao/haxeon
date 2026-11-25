package haxeon.ui.core;

import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;

/** A component's actual body root carries its native owner; ordinary descendants carry no owner field. */
internal class ScopeRootNode extends RenderNode {
	var owner:RenderScope;

	public function new(id:WidgetId, kind:LayoutVisualKind, style:Null<LayoutStyle>, owner:RenderScope) {
		super(id, kind, style);
		this.owner = owner;
	}

	override public function scopeOwner():Null<RenderScope> return owner;
	override public function setScopeOwner(owner:RenderScope):Void this.owner = owner;
}
