package nativekit.ui.docking;

/** Application-owned storage boundary for persisted workspace snapshots. */
interface DockWorkspacePersistence {
	function load(key:String):Null<String>;
	function save(key:String, value:String):Void;
}
