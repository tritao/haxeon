package runtime;

enum RuntimeDomainStatus {
	Inactive;
	Active;
	Failed(message:String);
}

/** Owns one plugin and native-module generation through explicit lifecycle stages. */
class RuntimeDomain {
	public final name:String;
	public var generation(default, null):Int = 0;
	public var status(default, null):RuntimeDomainStatus = Inactive;
	public var lastCleanupError(default, null):Null<String>;

	var current:Null<Plugin>;
	var currentModule:Dynamic;
	final retirementBacklog:Array<Dynamic> = [];
	final disposeModule:Null<Dynamic->Void>;

	public function new(name:String, ?disposeModule:Dynamic->Void) {
		if (name.length == 0)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime domain name cannot be empty");
		this.name = name;
		this.disposeModule = disposeModule;
	}

	public var active(get, never):Bool;
	public var retainedModuleCount(get, never):Int;

	function get_active():Bool
		return status == Active && current != null;

	function get_retainedModuleCount():Int
		return retirementBacklog.length;

	public function activate(plugin:Plugin):Void
		activateWithModule(plugin, null);

	public function activateWithModule(plugin:Plugin, module:Dynamic):Void {
		validateCandidate(plugin, module);
		if (status != Inactive || current != null || currentModule != null)
			throw new RuntimeError(RuntimeStatus.Incompatible, 'Runtime domain "$name" is not inactive');
		try
			plugin.activate()
		catch (error:Dynamic) {
			dispose(module);
			throw error;
		}
		current = plugin;
		currentModule = module;
		status = Active;
		generation++;
	}

	public function reload(plugin:Plugin):Void
		reloadWithModule(plugin, null);

	public function reloadWithModule(plugin:Plugin, module:Dynamic):Void {
		validateCandidate(plugin, module);
		if (status == Inactive) {
			activateWithModule(plugin, module);
			return;
		}
		if (!active)
			throw new RuntimeError(RuntimeStatus.Incompatible, 'Runtime domain "$name" requires explicit shutdown after failure');
		var previous = current,
			previousModule = currentModule,
			state:Null<String> = null;
		try {
			if (previous is ReloadablePlugin)
				state = cast(previous, ReloadablePlugin).saveState();
		} catch (error:Dynamic) {
			dispose(module);
			throw error;
		}
		try
			previous.deactivate()
		catch (error:Dynamic) {
			dispose(module);
			status = Failed('Previous generation deactivation failed: ${Std.string(error)}');
			throw error;
		}
		var candidateActivated = false;
		try {
			plugin.activate();
			candidateActivated = true;
			if (state != null && plugin is ReloadablePlugin)
				cast(plugin, ReloadablePlugin).restoreState(state);
		} catch (error:Dynamic) {
			if (candidateActivated)
				try
					plugin.deactivate()
				catch (_:Dynamic) {}
			dispose(module);
			recover(previous, error);
			throw error;
		}

		// Publication: from here onward the candidate remains the active generation.
		current = plugin;
		currentModule = module;
		status = Active;
		generation++;
		lastCleanupError = null;
		try
			dispose(previousModule)
		catch (error:Dynamic) {
			retirementBacklog.push(previousModule);
			lastCleanupError = Std.string(error);
			throw new RuntimeError(RuntimeStatus.Exception, 'Runtime domain "$name" published generation $generation but retirement failed: $lastCleanupError');
		}
	}

	public function deactivate():Void {
		if (status == Inactive)
			return;
		if (status == Active && current != null)
			try
				current.deactivate()
			catch (error:Dynamic) {
				status = Failed('Active generation deactivation failed: ${Std.string(error)}');
				throw error;
			}
		var module = currentModule;
		current = null;
		currentModule = null;
		try
			dispose(module)
		catch (error:Dynamic) {
			currentModule = module;
			status = Failed('Module disposal failed: ${Std.string(error)}');
			throw error;
		}
		while (retirementBacklog.length > 0) {
			var retired = retirementBacklog[0];
			try
				dispose(retired)
			catch (error:Dynamic) {
				status = Failed('Retired module disposal failed: ${Std.string(error)}');
				throw error;
			}
			retirementBacklog.shift();
		}
		status = Inactive;
		lastCleanupError = null;
	}

	function recover(previous:Plugin, cause:Dynamic):Void {
		try {
			previous.activate();
			status = Active;
		} catch (recovery:Dynamic) {
			status = Failed('Recovery failed after ${Std.string(cause)}: ${Std.string(recovery)}');
			throw new RuntimeError(RuntimeStatus.Exception, 'Runtime domain "$name" failed to recover: ${Std.string(recovery)}');
		}
	}

	function validateCandidate(plugin:Plugin, module:Dynamic):Void {
		if (plugin == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Cannot activate a null plugin");
		if (module != null && disposeModule == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, 'Runtime domain "$name" has no module disposer');
	}

	function dispose(module:Dynamic):Void {
		if (module == null)
			return;
		if (disposeModule == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, 'Runtime domain "$name" has no module disposer');
		disposeModule(module);
	}
}
