package haxeon.platform;

import nativekit.ffi.NativeKitTypes.Result as NativeResult;

/**
 * NativeKit's result codes, told apart for the packages that call it: a code that is the program's mistake throws a
 * `BindingError`, and any other is a `NativeKitError`, returned in a `Result` or thrown as a `NativeKitException`.
 * `diagnostic` is the calling module's last error (`nk_last_error` and the like).
 */
class NativeKitStatus {
	/** `Ok(value())`, or the failure `status` is. */
	public static function made<T>(status:NativeResult, operation:String, diagnostic:Null<String>,
			value:() -> T):Result<T, NativeKitError>
		return status == NativeResult.Ok ? Ok(value()) : Err(error(status, operation, diagnostic));

	/** `Ok()`, or the failure `status` is. */
	public static function result(status:NativeResult, operation:String,
			diagnostic:Null<String>):Result<Void, NativeKitError>
		return status == NativeResult.Ok ? Ok() : Err(error(status, operation, diagnostic));

	/** Does nothing for `Ok`; otherwise throws the failure `status` is. */
	public static function check(status:NativeResult, operation:String, diagnostic:Null<String>):Void {
		if (status != NativeResult.Ok)
			throw failure(status, operation, diagnostic);
	}

	/**
	 * What to throw for the failure `status`: a `BindingError` for the program's mistake, else a `NativeKitException`.
	 * The checked helpers the NativeKit bindings generate throw it.
	 */
	public static function failure(status:NativeResult, operation:String, diagnostic:Null<String>):PlatformError {
		var mistake = misuse(status);
		if (mistake != null)
			return new BindingError(mistake, operation, explanation(status, diagnostic));
		return new NativeKitException(meaning(status, diagnostic), operation, status.rawValue);
	}

	/** The `NativeKitError` the failure `status` is; a mistake of the program's throws its `BindingError`. */
	public static function error(status:NativeResult, operation:String, diagnostic:Null<String>):NativeKitError {
		var mistake = misuse(status);
		if (mistake != null)
			throw new BindingError(mistake, operation, explanation(status, diagnostic));
		return meaning(status, diagnostic);
	}

	/**
	 * The `NativeKitError` a failure `status` reported by an event is. An event has no call to throw from, so a code
	 * that would be the program's mistake is `Failed(code, reason)` here rather than a `BindingError`.
	 */
	public static function reported(status:NativeResult, diagnostic:Null<String>):NativeKitError
		return misuse(status) == null ? meaning(status, diagnostic)
			: Failed(status.rawValue, explanation(status, diagnostic));

	static function misuse(status:NativeResult):Null<BindingErrorKind>
		return switch status {
			case NativeResult.ErrorInvalidArgument, NativeResult.ErrorBufferTooSmall: InvalidArgument;
			case NativeResult.ErrorInvalidHandle: Disposed;
			case NativeResult.ErrorWrongThread, NativeResult.ErrorNotInitialized, NativeResult.ErrorAlreadyInitialized,
				NativeResult.ErrorInvalidRequest: InvalidState;
			case _: null;
		}

	static function meaning(status:NativeResult, diagnostic:Null<String>):NativeKitError {
		var reason = diagnostic == null ? "" : diagnostic;
		return switch status {
			case NativeResult.ErrorInvalidData: InvalidData(reason);
			case NativeResult.ErrorUnsupported: Unsupported(reason);
			case NativeResult.ErrorNotFound: NotFound;
			case NativeResult.ErrorPermissionDenied: PermissionDenied(reason);
			case NativeResult.ErrorCancelled, NativeResult.HttpCanceled, NativeResult.TransportCanceled: Cancelled;
			case NativeResult.ErrorQueueFull, NativeResult.HttpWouldBlock, NativeResult.TransportWouldBlock: Busy;
			case NativeResult.ErrorPayloadTooLarge, NativeResult.HttpResponseLimit,
				NativeResult.TransportReceiveOverflow:
				TooLarge;
			case NativeResult.ErrorOutOfMemory: OutOfMemory;
			case NativeResult.ErrorSurfaceLost: SurfaceLost;
			case NativeResult.HttpDns, NativeResult.TransportDns: Network(HostNotFound);
			case NativeResult.HttpConnection, NativeResult.TransportConnection: Network(ConnectionFailed(reason));
			case NativeResult.HttpTimeout, NativeResult.TransportTimeout: Network(TimedOut);
			case NativeResult.HttpTls: Network(TlsFailed(reason));
			case NativeResult.HttpProtocol, NativeResult.TransportProtocol: Network(ProtocolViolation(reason));
			case NativeResult.TransportClosed: Network(Closed);
			case NativeResult.TransportAddressInUse: Network(AddressInUse);
			case NativeResult.HttpRedirect: Network(TooManyRedirects);
			case NativeResult.HttpProxy: Network(ProxyFailed(reason));
			case _: Failed(status.rawValue, reason);
		}
	}

	static function explanation(status:NativeResult, diagnostic:Null<String>):String
		return diagnostic == null || diagnostic.length == 0 ? 'NativeKit result ${status.rawValue}'
			: '$diagnostic (NativeKit result ${status.rawValue})';
}
