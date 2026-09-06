package runtime;

import haxe.io.Bytes;

/** Optional migration contract. State is a RuntimeStateEnvelope encoded into host-owned bytes. */
interface ReloadablePlugin extends Plugin {
	function saveState():Bytes;
	function restoreState(state:Bytes):Void;
}
