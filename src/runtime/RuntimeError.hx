package runtime;

/** Stable runtime failure status paired with human-readable context. */
class RuntimeError extends haxe.Exception {
	public final status:RuntimeStatus;

	public function new(status:RuntimeStatus, message:String) {
		super(message);
		this.status = status;
	}
}
