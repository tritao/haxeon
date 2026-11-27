package haxeon.gpu;

import haxeon.platform.BindingError;
import haxeon.platform.BindingErrorKind;
import haxeon.platform.PlatformError;
import nativekit.ffi.NativeKitGpu;

/**
 * The GPU module's status codes, told apart: a code that is the program's mistake throws a `BindingError`, and any other
 * is a `GpuError`, returned in a `Result` or thrown as a `GpuException`.
 */
internal class GpuResult {
	/** Does nothing for `Ok`; otherwise throws the failure `status` is. */
	public static function check(status:GpuStatus, operation:String):Void {
		if (status != GpuStatus.Ok)
			throw failure(status, operation);
	}

	/** `Ok(value())`, or the `GpuError` that `status` is; a mistake of the program's throws. */
	public static function made<T>(status:GpuStatus, operation:String, value:() -> T):Result<T, GpuError> {
		if (status == GpuStatus.Ok)
			return Ok(value());
		var mistake = misuse(status);
		if (mistake != null)
			throw new BindingError(mistake, operation, explanation(status));
		return Err(error(status));
	}

	/** What to throw for the failure `status`: a `BindingError` for the program's mistake, else a `GpuException`. */
	public static function failure(status:GpuStatus, operation:String):PlatformError {
		var mistake = misuse(status);
		if (mistake != null)
			return new BindingError(mistake, operation, explanation(status));
		return new GpuException(error(status), operation, status.rawValue);
	}

	static function misuse(status:GpuStatus):Null<BindingErrorKind>
		return switch status {
			case GpuStatus.ErrorInvalidArgument, GpuStatus.ErrorBufferOverflow: InvalidArgument;
			case GpuStatus.ErrorInvalidHandle: Disposed;
			case GpuStatus.ErrorWrongState, GpuStatus.ErrorWrongThread: InvalidState;
			case _: null;
		}

	static function error(status:GpuStatus):GpuError {
		var reason = diagnostic();
		return switch status {
			case GpuStatus.ErrorUnsupported: Unsupported(reason);
			case GpuStatus.ErrorDeviceLost: DeviceLost;
			case GpuStatus.ErrorOutOfMemory: OutOfMemory;
			case _: Failed(status.rawValue, reason);
		}
	}

	static function diagnostic():String {
		var text = NativeKitGpu.nkgpu_last_error();
		return text == null ? "" : text;
	}

	static function explanation(status:GpuStatus):String {
		var text = diagnostic();
		return text.length == 0 ? 'GPU status ${status.rawValue}' : '$text (GPU status ${status.rawValue})';
	}
}
