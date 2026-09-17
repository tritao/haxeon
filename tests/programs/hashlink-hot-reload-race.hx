import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlHotReloadState;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlTypeKind;
import runtime.memory.ConditionVariable;
import runtime.memory.RawPtr;
import sys.thread.Thread;

typedef RaceGeneration = {
	final metadata:HlMetadataGeneration;
	final functions:HlFunctionVersionTable;
}

function buildGeneration(extraType:Bool):RaceGeneration {
	var metadata = new HlMetadataGeneration(128, 1),
		intType = metadata.builder.primitive(HlTypeKind.Int32Type),
		functionType = metadata.builder.functionType([], intType);
	metadata.addType(intType);
	metadata.addType(functionType);
	if (extraType)
		metadata.addType(metadata.builder.primitive(HlTypeKind.BoolType));
	metadata.defineModule([RawPtr.nullPtr()], [functionType]);
	return {
		metadata: metadata,
		functions: HlFunctionVersionTable.fromMetadata(metadata, [7])
	};
}

class ShutdownRaceControl {
	public final condition:ConditionVariable = ConditionVariable.create();

	var ready:Bool = false;
	var held:Bool = false;
	var holdRequested:Bool = false;
	var releaseRequested:Bool = false;
	var stopping:Bool = false;
	var done:Bool = false;
	var visitsValue:Int = 0;
	var lastRevision:Int = 0;
	var failuresValue:Int = 0;

	public function markReady():Void {
		condition.acquire();
		ready = true;
		condition.signal();
		condition.release();
	}

	public function waitReady():Void {
		condition.acquire();
		while (!ready)
			condition.wait();
		condition.release();
	}

	public function requestHold():Void {
		condition.acquire();
		holdRequested = true;
		condition.signal();
		condition.release();
	}

	public function claimHold():Bool {
		condition.acquire();
		var result = holdRequested;
		if (result)
			holdRequested = false;
		condition.release();
		return result;
	}

	public function markHeld():Void {
		condition.acquire();
		held = true;
		condition.signal();
		condition.release();
	}

	public function waitHeld():Void {
		condition.acquire();
		while (!held)
			condition.wait();
		condition.release();
	}

	public function releaseHeld():Void {
		condition.acquire();
		releaseRequested = true;
		condition.signal();
		condition.release();
	}

	public function waitForRelease():Void {
		condition.acquire();
		while (!releaseRequested)
			condition.wait();
		releaseRequested = false;
		condition.release();
	}

	public function markReleased():Void {
		condition.acquire();
		held = false;
		condition.signal();
		condition.release();
	}

	public function requestStop():Void {
		condition.acquire();
		stopping = true;
		condition.signal();
		condition.release();
	}

	public function isStopping():Bool {
		condition.acquire();
		var result = stopping;
		condition.release();
		return result;
	}

	public function visit(revision:Int):Void {
		condition.acquire();
		visitsValue++;
		if (revision <= 0 || revision < lastRevision)
			failuresValue++;
		if (revision > lastRevision)
			lastRevision = revision;
		condition.release();
	}

	public function markDone():Void {
		condition.acquire();
		done = true;
		condition.signal();
		condition.release();
	}

	public function waitDone():Void {
		condition.acquire();
		while (!done)
			condition.wait();
		condition.release();
	}

	public function visits():Int {
		condition.acquire();
		var result = visitsValue;
		condition.release();
		return result;
	}

	public function failures():Int {
		condition.acquire();
		var result = failuresValue;
		condition.release();
		return result;
	}

	public function close():Void
		condition.close();
}

function main():Int {
	var state = new HlHotReloadState(), initial = buildGeneration(false);
	state.stage(initial.metadata, initial.functions).commit();
	var control = new ShutdownRaceControl();
	Thread.create(function() {
		control.markReady();
		while (!control.isStopping()) {
			if (control.claimHold()) {
				var held = state.currentLease();
				control.markHeld();
				control.waitForRelease();
				held.release();
				control.markReleased();
				continue;
			}
			var lease = state.currentLease();
			control.visit(lease.generation.revision);
			lease.release();
			Sys.sleep(0.0001);
		}
		control.markDone();
	});
	control.waitReady();
	for (_ in 0...64) {
		var next = buildGeneration(true);
		state.stage(next.metadata, next.functions).commit();
		state.disposeRetired();
	}

	control.requestHold();
	control.waitHeld();
	var shutdownBlocked = false;
	try
		state.dispose()
	catch (error:Dynamic)
		shutdownBlocked = true;
	control.releaseHeld();
	control.requestStop();
	control.waitDone();
	state.dispose();
	var correct = shutdownBlocked && control.visits() > 0 && control.failures() == 0 && state.retiredCount == 0;
	control.close();
	return correct ? 42 : 1;
}
