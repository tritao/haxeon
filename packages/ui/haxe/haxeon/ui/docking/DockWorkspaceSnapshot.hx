package haxeon.ui.docking;

/** Versioned value snapshot suitable for project or user layout persistence. */
class DockWorkspaceSnapshot {
	public static inline var CurrentVersion:Int = 1;
	public final version:Int;
	public final root:DockNode;
	public final activePanelId:Null<String>;

	public function new(root:DockNode, activePanelId:Null<String>,
		version:Int = CurrentVersion, ?excludedPanels:Array<String>) {
		if (root == null || version <= 0)
			throw "Dock workspace snapshots require a root and positive version";
		this.version = version;
		// Filter transient panels as part of the defensive copy when requested.
		this.root = excludedPanels == null ? DockNodeTools.clone(root) : DockNodeTools.copyExcluding(root, excludedPanels);
		this.activePanelId = activePanelId;
	}
}
