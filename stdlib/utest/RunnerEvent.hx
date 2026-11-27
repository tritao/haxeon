package utest;

import utest.Runner;

/** Synchronous event carrying a Runner. */
class RunnerEvent {
	final listeners:Array<Runner->Void> = [];

	/** An event no one listens to yet. */
	public function new() {}

	/** Calls `listener` on each dispatch, after the listeners added before it. */
	public function add(listener:Runner->Void):Void {
		listeners.push(listener);
	}

	/** Calls each listener with `value`, in the order they were added. */
	public function dispatch(value:Runner):Void {
		for (listener in listeners)
			listener(value);
	}
}
