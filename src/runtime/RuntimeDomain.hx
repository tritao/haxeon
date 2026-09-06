package runtime;

import haxe.io.Bytes;

enum RuntimeDomainStatus {
	Inactive;
	Active;
	Failed(message:String);
}

private enum GenerationActivation {
	GenerationInactive;
	GenerationActive;
	GenerationUnknown;
}

private class OwnedGeneration {
	public final plugin:Plugin;
	public final module:Dynamic;
	public var activation:GenerationActivation;

	public function new(plugin:Plugin, module:Dynamic) {
		this.plugin = plugin;
		this.module = module;
		activation = GenerationInactive;
	}
}

/** Owns plugin and native-module generations through explicit lifecycle stages. */
class RuntimeDomain {
	public final name:String;
	public var generation(default, null):Int = 0;
	public var status(default, null):RuntimeDomainStatus = Inactive;
	public var lastCleanupError(default, null):Null<String>;

	var current:Null<OwnedGeneration>;
	final retirementBacklog:Array<OwnedGeneration> = [];
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
		return status == Active && current != null && current.activation == GenerationActive;

	function get_retainedModuleCount():Int
		return retirementBacklog.length;

	public function activate(plugin:Plugin):Void
		activateWithModule(plugin, null);

	public function activateWithModule(plugin:Plugin, module:Dynamic):Void {
		validateCandidate(plugin, module);
		if (status != Inactive || current != null)
			throw new RuntimeError(RuntimeStatus.Incompatible, 'Runtime domain "$name" is not inactive');
		var candidate = new OwnedGeneration(plugin, module);
		try {
			plugin.activate();
			candidate.activation = GenerationActive;
		} catch (error:Dynamic) {
			if (!tryDisposeInactive(candidate))
				fail('Initial candidate disposal failed after ${Std.string(error)}: $lastCleanupError');
			throw error;
		}
		current = candidate;
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
			candidate = new OwnedGeneration(plugin, module),
			state:Null<Bytes> = null;
		try {
			if (Std.isOfType(previous.plugin, ReloadablePlugin))
				state = copyState(cast(previous.plugin, ReloadablePlugin).saveState());
		} catch (error:Dynamic) {
			tryDisposeInactive(candidate);
			throw error;
		}
		try {
			previous.plugin.deactivate();
			previous.activation = GenerationInactive;
		} catch (error:Dynamic) {
			previous.activation = GenerationUnknown;
			tryDisposeInactive(candidate);
			fail('Previous generation deactivation failed: ${Std.string(error)}');
		}
		try {
			plugin.activate();
			candidate.activation = GenerationActive;
			if (state != null && Std.isOfType(plugin, ReloadablePlugin))
				cast(plugin, ReloadablePlugin).restoreState(state);
		} catch (error:Dynamic) {
			if (!deactivateForRetirement(candidate)) {
				retirementBacklog.push(candidate);
				fail('Candidate cleanup failed after ${Std.string(error)}: $lastCleanupError');
			}
			tryDisposeInactive(candidate);
			recover(previous, error);
			throw error;
		}

		current = candidate;
		status = Active;
		generation++;
		lastCleanupError = null;
		try
			dispose(previous.module)
		catch (error:Dynamic) {
			retirementBacklog.push(previous);
			lastCleanupError = Std.string(error);
			throw new RuntimeError(RuntimeStatus.Exception, 'Runtime domain "$name" published generation $generation but retirement failed: $lastCleanupError');
		}
	}

	static function copyState(state:Bytes):Bytes {
		if (state == null)
			throw new RuntimeError(RuntimeStatus.BadFormat, "Reloadable plugin returned null state");
		return state.sub(0, state.length);
	}

	public function deactivate():Void {
		if (status == Inactive)
			return;
		var owned = current;
		if (owned != null) {
			if (!deactivateForRetirement(owned))
				fail('Active generation deactivation failed: $lastCleanupError');
			try
				dispose(owned.module)
			catch (error:Dynamic) {
				lastCleanupError = Std.string(error);
				fail('Module disposal failed: $lastCleanupError');
			}
			current = null;
		}
		while (retirementBacklog.length > 0) {
			var retired = retirementBacklog[0];
			if (!deactivateForRetirement(retired))
				fail('Retired generation deactivation failed: $lastCleanupError');
			try
				dispose(retired.module)
			catch (error:Dynamic) {
				lastCleanupError = Std.string(error);
				fail('Retired module disposal failed: $lastCleanupError');
			}
			retirementBacklog.shift();
		}
		status = Inactive;
		lastCleanupError = null;
	}

	function recover(previous:OwnedGeneration, cause:Dynamic):Void {
		try {
			previous.plugin.activate();
			previous.activation = GenerationActive;
			status = Active;
		} catch (recovery:Dynamic) {
			previous.activation = GenerationUnknown;
			fail('Recovery failed after ${Std.string(cause)}: ${Std.string(recovery)}');
		}
	}

	function deactivateForRetirement(owned:OwnedGeneration):Bool {
		if (owned.activation == GenerationInactive)
			return true;
		try {
			owned.plugin.deactivate();
			owned.activation = GenerationInactive;
			return true;
		} catch (error:Dynamic) {
			owned.activation = GenerationUnknown;
			lastCleanupError = Std.string(error);
			return false;
		}
	}

	function tryDisposeInactive(owned:OwnedGeneration):Bool {
		try
			dispose(owned.module)
		catch (error:Dynamic) {
			retirementBacklog.push(owned);
			lastCleanupError = Std.string(error);
			return false;
		}
		return true;
	}

	function fail(message:String):Dynamic {
		status = Failed(message);
		throw new RuntimeError(RuntimeStatus.Exception, 'Runtime domain "$name": $message');
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
