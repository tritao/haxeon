package utest;

import utest.TestProgress;

/** Synchronous event carrying one completed test result. */
class ProgressEvent {
	final listeners:Array<TestProgress->Void> = [];

	/** An event no one listens to yet. */
	public function new() {}

	/** Calls `listener` on each dispatch, after the listeners added before it. */
	public function add(listener:TestProgress->Void):Void {
		listeners.push(listener);
	}

	/** Calls each listener with `value`, in the order they were added. */
	public function dispatch(value:TestProgress):Void {
		for (listener in listeners)
			listener(value);
	}
}
