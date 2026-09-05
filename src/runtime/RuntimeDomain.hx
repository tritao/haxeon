package runtime;

/**
	Owns one plugin generation and makes structural reload behavior explicit.

	The native module swap is deliberately outside this class for now: the host
	stages a new module and plugin instance, then asks the domain to commit the
	lifecycle transition. A failed transition leaves the previous generation
	active whenever recovery is possible.
 */
class RuntimeDomain {
	public final name:String;
	public var generation(default, null):Int = 0;

	var current:Null<Plugin>;

	public function new(name:String) {
		if (name.length == 0)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime domain name cannot be empty");
		this.name = name;
	}

	public var active(get, never):Bool;

	function get_active():Bool
		return current != null;

	public function activate(plugin:Plugin):Void {
		if (plugin == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Cannot activate a null plugin");
		if (current != null)
			throw new RuntimeError(RuntimeStatus.Incompatible, 'Runtime domain "$name" is already active');
		plugin.activate();
		current = plugin;
		generation++;
	}

	public function reload(plugin:Plugin):Void {
		if (plugin == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Cannot reload a null plugin");
		if (current == null) {
			activate(plugin);
			return;
		}
		var previous = current,
			state:Null<String> = previous is ReloadablePlugin ? cast(previous, ReloadablePlugin).saveState() : null,
			activated = false;
		try {
			previous.deactivate();
			plugin.activate();
			activated = true;
			if (state != null && plugin is ReloadablePlugin)
				cast(plugin, ReloadablePlugin).restoreState(state);
			current = plugin;
			generation++;
		} catch (error:Dynamic) {
			if (activated)
				try
					plugin.deactivate()
				catch (_:Dynamic) {}
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
	}
}
