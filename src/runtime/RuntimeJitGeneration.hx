package runtime;

/** Owns one published host-runtime JIT allocation and its Haxe lifecycle state. */
class RuntimeJitGeneration {
	public final revision:Int;
	public var state(default, null):Int;

	final backend:RuntimeJitBackend;
	final code:RuntimeJitCodeHandle;
	var released:Bool = false;

	public function new(backend:RuntimeJitBackend, revision:Int, code:RuntimeJitCodeHandle, publishedState:Int) {
		if (backend == null || code == null || revision < 0)
			throw "Runtime JIT generation ownership requires a backend, revision, and code handle";
		this.backend = backend;
		this.revision = revision;
		this.code = code;
		state = publishedState;
	}

	/** Return the native revision while the external allocation is live. */
	public function codeRevision():Int
		return released ? -1 : backend.codeRevision(code);

	/** Move this generation into the host retirement lifecycle. */
	@:allow(runtime.Runtime)
	function markRetiring(retiringState:Int):Void
		state = retiringState;

	/** Release the executable allocation exactly once. */
	public function release():Bool {
		if (released)
			return true;
		if (!backend.releaseCode(code))
			return false;
		released = true;
		return true;
	}
}
