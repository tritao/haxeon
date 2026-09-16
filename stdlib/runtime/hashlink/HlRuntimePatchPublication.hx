package runtime.hashlink;

/** Native result for one externally loaded runtime patch publication. */
class HlRuntimePatchPublication {
	public final status:Int;
	public final code:Null<HlRuntimeJitCodeHandle>;

	public function new(status:Int, code:Null<HlRuntimeJitCodeHandle>) {
		this.status = status;
		this.code = code;
	}
}
