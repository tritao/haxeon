package haxeon.ui.docking;

import haxeon.ui.icons.IconName;

/** View-independent metadata for one registered dock panel. */
class DockPanelDescriptor {
	public final id:String;
	public final title:String;
	public var badgeCount(default, null):Int = 0;
	@:allow(haxeon.ui.docking.DockWorkspaceModel)
	function setBadgeCount(value:Int):Void badgeCount = value;
	public final closable:Bool;
	public final enabled:Bool;
	public final icon:Null<IconName>;
	public final headerMode:DockPanelHeaderMode;
	public final grouping:Null<DockPanelGrouping>;

	public function new(id:String, title:String, closable:Bool = true, enabled:Bool = true,
			?icon:IconName, headerMode:DockPanelHeaderMode = DockPanelHeaderMode.Dock,
			?grouping:DockPanelGrouping) {
		if (id == null || id.length == 0 || title == null || title.length == 0)
			throw "Dock panels require a stable ID and title";
		this.id = id;
		this.title = title;
		this.closable = closable;
		this.enabled = enabled;
		this.icon = icon;
		this.headerMode = headerMode;
		this.grouping = grouping;
	}
}
