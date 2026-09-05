package compiler.service;

/** Cooperative cancellation shared by compiler and editor-service requests. */
class CancellationToken {
	public var cancelled(default, null):Bool = false;

	public function new() {}

	public function cancel():Void
		cancelled = true;

	public function check():Void {
		if (cancelled)
			throw new CancellationError();
	}
}
