package runtime;

/** Stable runtime failure status paired with human-readable context. */
class RuntimeError {
	public final status:RuntimeStatus;
	public final message:String;

	public function new(status:RuntimeStatus, message:String) {
		this.status = status;
		this.message = message;
	}

	public function toString():String
		return message;
}
