package runtime.hashlink;

/** Native result for one externally loaded runtime patch publication. */
class HlRuntimePatchPublication {
	public final status:Int;
	public final code:Null<hl.Abstract<"realtime_jit_code">>;

	public function new(status:Int, code:Null<hl.Abstract<"realtime_jit_code">>) {
		this.status = status;
		this.code = code;
	}
}
