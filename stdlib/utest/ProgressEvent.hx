package utest;

import utest.TestProgress;

/** Synchronous event carrying one completed test result. */
class ProgressEvent {
	final listeners:Array<TestProgress->Void> = [];

	public function new() {}

	public function add(listener:TestProgress->Void):Void {
		listeners.push(listener);
	}

	public function dispatch(value:TestProgress):Void {
		for (listener in listeners)
			listener(value);
	}
}
