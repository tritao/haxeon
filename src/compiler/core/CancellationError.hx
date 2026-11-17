package compiler.core;

/** Internal control-flow exception used to unwind a cancelled request. */
class CancellationError extends haxe.Exception {
	public function new()
		super("compiler.core.CancellationError");
}
