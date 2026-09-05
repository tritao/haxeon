import runtime.Plugin;
import runtime.ReloadablePlugin;
import runtime.RuntimeDomain;

class RuntimeDomainMain {
	static function main():Void {
		var events:Array<String> = [], domain = new RuntimeDomain("search");
		var first = new TestPlugin("first", events),
			second = new TestPlugin("second", events);
		first.state = "cursor:4";
		domain.activate(first);
		if (!domain.active || domain.generation != 1 || events.join(",") != "first.activate")
			throw "runtime domain did not activate the first generation";
		try {
			domain.activate(second);
			throw "runtime domain accepted a second activation";
		} catch (error:runtime.RuntimeError) {}
		domain.reload(second);
		if (!domain.active
			|| domain.generation != 2
			|| second.state != "cursor:4"
			|| events.join(",") != "first.activate,first.save,first.deactivate,second.activate,second.restore")
			throw "runtime domain did not migrate state in order";
		var failing = new TestPlugin("failing", events);
		failing.failActivation = true;
		try {
			domain.reload(failing);
			throw "runtime domain accepted a failed generation";
		} catch (error:String) {}
		if (domain.generation != 2 || !domain.active || events[events.length - 1] != "second.activate")
			throw "runtime domain did not recover the previous generation";
		var liveFailure = new TestPlugin("live-failure", events);
		liveFailure.failSaveState = true;
		var saveFailure = new TestPlugin("save-candidate", events);
		var saveFailureModule:Dynamic = {};
		var saveFailureDisposed = false,
			ownedFailure = new RuntimeDomain("owned-failure", function(module:Dynamic):Void {
				if (module == saveFailureModule)
					saveFailureDisposed = true;
			});
		ownedFailure.activateWithModule(liveFailure, {});
		try {
			ownedFailure.reloadWithModule(saveFailure, saveFailureModule);
			throw "runtime domain accepted a state-save failure";
		} catch (error:String) {}
		if (!ownedFailure.active || ownedFailure.generation != 1 || !saveFailureDisposed)
			throw "runtime domain did not dispose a candidate after state-save failure";
		domain.deactivate();
		if (domain.active || domain.generation != 2)
			throw "runtime domain did not deactivate cleanly";
		var disposed = 0, owned = new RuntimeDomain("owned", function(_) disposed++), firstModule:Dynamic = {}, secondModule:Dynamic = {};
		owned.activateWithModule(new TestPlugin("owned-first", events), firstModule);
		owned.reloadWithModule(new TestPlugin("owned-second", events), secondModule);
		if (disposed != 1)
			throw "runtime domain did not dispose the previous module after commit";
		owned.deactivate();
		if (disposed != 2)
			throw "runtime domain did not dispose the active module on deactivate";
		Sys.println("PASS: runtime domain lifecycle and state migration contract");
	}
}

private class TestPlugin implements ReloadablePlugin {
	public final name:String;

	final events:Array<String>;

	public var state:String = "";
	public var failActivation:Bool = false;
	public var failSaveState:Bool = false;

	public function new(name:String, events:Array<String>) {
		this.name = name;
		this.events = events;
	}

	public function activate():Void {
		events.push('$name.activate');
		if (failActivation)
			throw 'activation failed for $name';
	}

	public function deactivate():Void
		events.push('$name.deactivate');

	public function saveState():String {
		events.push('$name.save');
		if (failSaveState)
			throw 'state save failed for $name';
		return state;
	}

	public function restoreState(value:String):Void {
		events.push('$name.restore');
		state = value;
	}
}
