package haxeon.ui.widgets.sidebar;

/** Registration metadata; sizing belongs to the sidebar container. */
class SidebarModeOptions {
	/** The destination's name in the strip: required. */
	public final label:String;

	/** Its place in the default order: lower first. */
	public final order:Int;

	/** Whether it starts listed. */
	public final visible:Bool;

	/** Options for a destination named `label`. */
	public function new(label:String, order:Int = 0, visible:Bool = true) {
		this.label = label;
		this.order = order;
		this.visible = visible;
	}
}
