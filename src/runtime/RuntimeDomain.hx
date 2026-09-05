package runtime;

/**
	Owns one plugin generation and makes structural reload behavior explicit.

	A domain owns the plugin instance and, when supplied, its native module
	generation. Candidate modules are staged before publication; a failed
	lifecycle transition disposes the candidate and leaves the previous
	generation active whenever recovery is possible.
 */
class RuntimeDomain {
	public final name:String;
	public var generation(default, null):Int = 0;

	var current:Null<Plugin>;
	var currentModule:Dynamic;
	final disposeModule:Null<Dynamic->Void>;

	public function new(name:String, ?disposeModule:Dynamic->Void) {
		if (name.length == 0)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime domain name cannot be empty");
		this.name = name;
		this.disposeModule = disposeModule;
	}

	public var active(get, never):Bool;

	function get_active():Bool
		return current != null;

	public function activate(plugin:Plugin):Void {
		activateWithModule(plugin, null);
	}

	public function activateWithModule(plugin:Plugin, module:Dynamic):Void {
		if (plugin == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Cannot activate a null plugin");
		if (module != null && disposeModule == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, 'Runtime domain "$name" has no module disposer');
		if (current != null)
			throw new RuntimeError(RuntimeStatus.Incompatible, 'Runtime domain "$name" is already active');
		try {
			plugin.activate();
		} catch (error:Dynamic) {
			dispose(module);
			throw error;
		}
		current = plugin;
		currentModule = module;
		generation++;
	}

	public function reload(plugin:Plugin):Void {
		reloadWithModule(plugin, null);
	}

	public function reloadWithModule(plugin:Plugin, module:Dynamic):Void {
		if (plugin == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Cannot reload a null plugin");
		if (current == null) {
			activateWithModule(plugin, module);
			return;
		}
		var previous = current,
			previousModule = currentModule,
			state:Null<String> = null,
			activated = false;
		try {
			if (previous is ReloadablePlugin)
				state = cast(previous, ReloadablePlugin).saveState();
			previous.deactivate();
			plugin.activate();
			activated = true;
			if (state != null && plugin is ReloadablePlugin)
				cast(plugin, ReloadablePlugin).restoreState(state);
			current = plugin;
			currentModule = module;
			generation++;
			dispose(previousModule);
		} catch (error:Dynamic) {
			if (activated)
				try
					plugin.deactivate()
				catch (_:Dynamic) {}
			dispose(module);
			try
				previous.activate()
			catch (recovery:Dynamic)
				throw new RuntimeError(RuntimeStatus.Exception, 'Runtime domain "$name" failed to recover: ${Std.string(recovery)}');
			throw error;
		}
	}

	public function deactivate():Void {
		if (current == null)
			return;
		var previous = current;
		previous.deactivate();
		current = null;
		var module = currentModule;
		currentModule = null;
		dispose(module);
	}

	function dispose(module:Dynamic):Void {
		if (module == null)
			return;
		if (disposeModule == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, 'Runtime domain "$name" has no module disposer');
		disposeModule(module);
	}
}
