package runtime;

/** A generation-owned value that keeps its native module alive until release. */
class RetainedValue {
	final module:LoadedModule;
	var value:Dynamic;

	@:allow(runtime.Runtime)
	function new(module:LoadedModule, value:Dynamic) {
		this.module = module;
		this.value = value;
	}

	@:allow(runtime.Runtime)
	function get():Dynamic {
		if (value == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Retained runtime value has been released");
		return value;
	}

	@:allow(runtime.Runtime)
	function access<T>(operation:hl.Abstract<"realtime_module">->Dynamic->T):T {
		var retained = value;
		if (retained == null)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Retained runtime value has been released");
		return module.accessBorrowed(function(handle) return operation(handle, retained));
	}

	public function release():Void {
		if (value == null)
			return;
		value = null;
		module.release();
	}
}
