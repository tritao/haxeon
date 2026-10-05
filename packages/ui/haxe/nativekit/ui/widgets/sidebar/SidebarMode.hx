package nativekit.ui.widgets.sidebar;

import nativekit.ui.core.View;

/** A stable mode with a provider evaluated only while its page is mounted. */
class SidebarMode {
	public final id:String;
	public final provider:Void->View;
	public final label:String;
	public final order:Int;
	public final sequence:Int;
	public var visible:Bool;
	public function new(id:String, provider:Void->View, options:SidebarModeOptions, sequence:Int) {
		this.sequence = sequence;
		this.id = id; this.provider = provider; label = options.label; order = options.order;
		visible = options.visible;
	}
}
