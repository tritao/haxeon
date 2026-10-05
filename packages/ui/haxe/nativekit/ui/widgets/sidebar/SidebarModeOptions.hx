package nativekit.ui.widgets.sidebar;

/** Registration metadata; sizing belongs to the sidebar container. */
class SidebarModeOptions {
	public final label:String;
	public final order:Int;
	public final visible:Bool;
	public function new(label:String, order:Int = 0, visible:Bool = true) {
		this.label = label; this.order = order; this.visible = visible;
	}
}
