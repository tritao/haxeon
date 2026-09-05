package runtime;

/** Optional migration contract for structural plugin reloads. */
interface ReloadablePlugin extends Plugin {
	function saveState():String;
	function restoreState(state:String):Void;
}
