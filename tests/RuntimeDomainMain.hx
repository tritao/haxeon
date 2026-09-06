import runtime.Plugin;
import runtime.ReloadablePlugin;
import runtime.RuntimeDomain;
import runtime.RuntimeDomain.RuntimeDomainStatus;
import runtime.RuntimeStateEnvelope;

class RuntimeDomainMain {
	static function main():Void {
		testStateEnvelope();
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
		if (events.indexOf("failing.deactivate") >= 0)
			throw "runtime domain deactivated a candidate that never activated";
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
		if (!ownedFailure.active
			|| ownedFailure.generation != 1
			|| !saveFailureDisposed
			|| count(events, "live-failure.activate") != 1
			|| events.indexOf("live-failure.deactivate") >= 0)
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
		testPostPublicationCleanup(events);
		testRestoreFailure(events);
		testCandidateCleanupFailure(events);
		testRecoveryFailure(events);
		Sys.println("PASS: runtime domain lifecycle and state migration contract");
	}

	static function testStateEnvelope():Void {
		var encoded = new RuntimeStateEnvelope("cursor:4").encode();
		if (RuntimeStateEnvelope.decode(encoded).payload != "cursor:4"
			|| encoded.compare(new RuntimeStateEnvelope("cursor:4").encode()) != 0)
			throw "runtime state envelope did not round trip deterministically";
		var unsupported = encoded.sub(0, encoded.length);
		unsupported.set(3, RuntimeStateEnvelope.VERSION + 1);
		try {
			RuntimeStateEnvelope.decode(unsupported);
			throw "runtime state envelope accepted an unknown version";
		} catch (error:String) {
			if (error != "Unsupported runtime state envelope")
				throw error;
		}
	}

	static function testRestoreFailure(events:Array<String>):Void {
		var domain = new RuntimeDomain("restore"),
			previous = new TestPlugin("restore-first", events),
			candidate = new TestPlugin("restore-candidate", events);
		previous.state = "cursor:8";
		candidate.failRestoreState = true;
		domain.activate(previous);
		try {
			domain.reload(candidate);
			throw "runtime domain accepted failed state restoration";
		} catch (error:String) {}
		var suffix = events.slice(events.length - 6).join(",");
		if (!domain.active
			|| domain.generation != 1
			|| suffix != "restore-first.save,restore-first.deactivate,restore-candidate.activate,restore-candidate.restore,restore-candidate.deactivate,restore-first.activate")
			throw "runtime domain did not recover in order after restore failure";
		domain.deactivate();
	}

	static function testPostPublicationCleanup(events:Array<String>):Void {
		var firstModule:Dynamic = {},
			secondModule:Dynamic = {},
			failFirstDisposal = true;
		var domain = new RuntimeDomain("cleanup", function(module:Dynamic):Void {
			if (module == firstModule && failFirstDisposal) {
				failFirstDisposal = false;
				throw "retirement failed";
			}
		});
		var first = new TestPlugin("cleanup-first", events),
			second = new TestPlugin("cleanup-second", events);
		domain.activateWithModule(first, firstModule);
		try {
			domain.reloadWithModule(second, secondModule);
			throw "runtime domain hid a retirement failure";
		} catch (error:runtime.RuntimeError) {}
		if (!domain.active
			|| domain.generation != 2
			|| domain.retainedModuleCount != 1
			|| domain.lastCleanupError == null
			|| events.indexOf("cleanup-second.deactivate") >= 0)
			throw "post-publication cleanup failure rolled back the published generation";
		domain.deactivate();
		if (domain.status != Inactive || domain.retainedModuleCount != 0)
			throw "runtime domain did not retry retained module cleanup";
	}

	static function testCandidateCleanupFailure(events:Array<String>):Void {
		var disposed = 0, domain = new RuntimeDomain("candidate-cleanup", function(_) disposed++),
			previous = new TestPlugin("candidate-cleanup-first", events), candidate = new TestPlugin("candidate-cleanup-second", events);
		previous.state = "cursor:9";
		candidate.failRestoreState = true;
		candidate.failDeactivationCount = 1;
		domain.activateWithModule(previous, {});
		try {
			domain.reloadWithModule(candidate, {});
			throw "runtime domain accepted a candidate whose cleanup failed";
		} catch (error:runtime.RuntimeError) {}
		if (domain.active
			|| domain.retainedModuleCount != 1
			|| disposed != 0
			|| count(events, "candidate-cleanup-second.deactivate") != 1)
			throw "runtime domain disposed or forgot a partially active candidate";
		domain.deactivate();
		if (domain.status != Inactive
			|| domain.retainedModuleCount != 0
			|| disposed != 2
			|| count(events, "candidate-cleanup-second.deactivate") != 2)
			throw "runtime domain did not retry candidate deactivation before disposal";
	}

	static function testRecoveryFailure(events:Array<String>):Void {
		var disposed = 0, domain = new RuntimeDomain("recovery", function(_) disposed++);
		var previous = new TestPlugin("recovery-first", events),
			candidate = new TestPlugin("recovery-candidate", events);
		domain.activateWithModule(previous, {});
		previous.failActivation = true;
		candidate.failActivation = true;
		try {
			domain.reloadWithModule(candidate, {});
			throw "runtime domain accepted failed candidate and recovery";
		} catch (error:runtime.RuntimeError) {}
		switch domain.status {
			case Failed(_):
			case _:
				throw "runtime domain claimed failed recovery was active";
		}
		if (domain.active || domain.generation != 1 || disposed != 1)
			throw "failed recovery changed generation or candidate ownership";
		domain.deactivate();
		if (domain.status != Inactive || disposed != 2)
			throw "failed runtime domain could not be shut down";
	}

	static function count(events:Array<String>, expected:String):Int {
		var found = 0;
		for (event in events)
			if (event == expected)
				found++;
		return found;
	}
}

private class TestPlugin implements ReloadablePlugin {
	public final name:String;

	final events:Array<String>;

	public var state:String = "";
	public var failActivation:Bool = false;
	public var failSaveState:Bool = false;
	public var failRestoreState:Bool = false;
	public var failDeactivationCount:Int = 0;

	public function new(name:String, events:Array<String>) {
		this.name = name;
		this.events = events;
	}

	public function activate():Void {
		events.push('$name.activate');
		if (failActivation)
			throw 'activation failed for $name';
	}

	public function deactivate():Void {
		events.push('$name.deactivate');
		if (failDeactivationCount > 0) {
			failDeactivationCount--;
			throw 'deactivation failed for $name';
		}
	}

	public function saveState():String {
		events.push('$name.save');
		if (failSaveState)
			throw 'state save failed for $name';
		return state;
	}

	public function restoreState(value:String):Void {
		events.push('$name.restore');
		if (failRestoreState)
			throw 'state restore failed for $name';
		state = value;
	}
}
