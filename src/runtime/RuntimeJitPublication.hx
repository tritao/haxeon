package runtime;

/** Result of publishing one Haxe-owned patch through the native JIT backend. */
class RuntimeJitPublication {
	public final status:RuntimeStatus;
	public final code:RuntimeJitCodeHandle;

	public function new(status:RuntimeStatus, code:RuntimeJitCodeHandle) {
		this.status = status;
		this.code = code;
	}
}
