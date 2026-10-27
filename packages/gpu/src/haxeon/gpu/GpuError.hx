package haxeon.gpu;

/** GPU adapter status codes belong to their own domain, separate from nk_result. */
class GpuError extends haxeon.platform.NativeError {
	public function new(status:Int, operation:String, diagnostic:Null<String>)
		super("nativekit-gpu", status, operation, diagnostic);
}
