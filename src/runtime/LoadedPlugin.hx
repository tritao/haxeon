package runtime;

/**
	Adapter for a plugin generation whose lifecycle functions live in a loaded
	HashLink module. The stable function ids come from the compiler's runtime
	identity manifest, so the adapter remains valid across compatible patches.
 */
class LoadedPlugin implements ReloadablePlugin {
	public final module:LoadedModule;
	public final activateIndex:Int;
	public final deactivateIndex:Int;
	public final saveStateIndex:Int;
	public final restoreStateIndex:Int;
	public var restoredState(default, null):Null<String>;

	public function new(module:LoadedModule, activateIndex:Int, deactivateIndex:Int, saveStateIndex:Int, restoreStateIndex:Int) {
		if (module == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Loaded plugin module cannot be null");
		this.module = module;
		this.activateIndex = activateIndex;
		this.deactivateIndex = deactivateIndex;
		this.saveStateIndex = saveStateIndex;
		this.restoreStateIndex = restoreStateIndex;
		this.restoredState = null;
	}

	public function activate():Void
		Runtime.callVoid(module, activateIndex);

	public function deactivate():Void
		Runtime.callVoid(module, deactivateIndex);

	public function saveState():String
		return Runtime.callString(module, saveStateIndex);

	public function restoreState(state:String):Void {
		restoredState = state;
		Runtime.callStringArg(module, restoreStateIndex, state);
	}
}
