package nativekit.ui.docking;

/** Panels share dock tabs only within the same group; standalone panels split. */
class DockPanelGrouping {
	public final group:String;
	public final shareTabs:Bool;

	public function new(group:String, shareTabs:Bool = true) {
		if (group == null || group.length == 0) throw "Dock grouping requires a name";
		this.group = group;
		this.shareTabs = shareTabs;
	}
}
