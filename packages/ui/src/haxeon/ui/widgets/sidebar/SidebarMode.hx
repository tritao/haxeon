package haxeon.ui.widgets.sidebar;

import haxeon.ui.core.View;

/** A stable mode with a provider evaluated only while its page is mounted. */
class SidebarMode {
	/** Identifies the destination. */
	public final id:String;

	/** Builds its content, only while it is shown. */
	public final provider:Void->View;

	/** Its name in the strip. */
	public final label:String;

	/** Its place in the default order: lower first. */
	public final order:Int;
	internal final sequence:Int;

	/** Whether it is listed; change it with `SidebarModel.setModeVisible`. */
	public var visible:Bool;
	internal function new(id:String, provider:Void->View, options:SidebarModeOptions, sequence:Int) {
		this.sequence = sequence;
		this.id = id;
		this.provider = provider;
		label = options.label;
		order = options.order;
		visible = options.visible;
	}
}
