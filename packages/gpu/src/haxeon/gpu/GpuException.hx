package haxeon.gpu;

/** A `GpuError` thrown by an API that has no `Result` for it, such as a draw whose device was lost. */
class GpuException extends haxeon.platform.PlatformError {
	/** What failed. */
	public final error:GpuError;

	/** `error`, raised by `operation`; `code` is the GPU module's status code. */
	public function new(error:GpuError, operation:String, code:Int) {
		super("nativekit-gpu", code, operation, error.describe());
		this.error = error;
	}
}
