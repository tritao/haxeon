package utest;

import utest.Runner;

/** Synchronous event carrying a Runner. */
class RunnerEvent {
	final listeners:Array<Runner->Void> = [];

	public function new() {}

	public function add(listener:Runner->Void):Void {
		listeners.push(listener);
	}

	public function dispatch(value:Runner):Void {
		for (listener in listeners)
			listener(value);
	}
}
