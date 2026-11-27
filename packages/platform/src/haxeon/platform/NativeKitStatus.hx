package haxeon.platform;

import nativekit.ffi.NativeKitTypes.Result as NativeResult;

/**
 * NativeKit's result codes, told apart for the packages that call it: a code that is the program's mistake throws a
 * `BindingError`, and any other is a `NativeKitError`, returned in a `Result` or thrown as a `NativeKitException`.
 * `diagnostic` is the calling module's last error (`nk_last_error` and the like), and `invalidArgument` says what
 * `InvalidArgument` means at the call (`Misuse`, the default).
 */
class NativeKitStatus {
	/** `Ok(value())`, or the failure `status` is. */
	public static function made<T>(status:NativeResult, operation:String, diagnostic:Null<String>, value:() -> T,
			invalidArgument:InvalidArgumentMeans = Misuse):Result<T, NativeKitError>
		return status == NativeResult.Ok ? Ok(value()) : Err(error(status, operation, diagnostic, invalidArgument));

	/** `Ok()`, or the failure `status` is. */
	public static function result(status:NativeResult, operation:String, diagnostic:Null<String>,
			invalidArgument:InvalidArgumentMeans = Misuse):Result<Void, NativeKitError>
		return status == NativeResult.Ok ? Ok() : Err(error(status, operation, diagnostic, invalidArgument));

	/** Does nothing for `Ok`; otherwise throws the failure `status` is. */
	public static function check(status:NativeResult, operation:String, diagnostic:Null<String>,
			invalidArgument:InvalidArgumentMeans = Misuse):Void {
		if (status != NativeResult.Ok)
			throw failure(status, operation, diagnostic, invalidArgument);
	}

	/**
	 * What to throw for the failure `status`: a `BindingError` for the program's mistake, else a `NativeKitException`.
	 * The checked helpers the NativeKit bindings generate throw it.
	 */
	public static function failure(status:NativeResult, operation:String, diagnostic:Null<String>,
			invalidArgument:InvalidArgumentMeans = Misuse):PlatformError {
		var mistake = misuse(status, invalidArgument);
		if (mistake != null)
			return new BindingError(mistake, operation, explanation(status, diagnostic));
		return new NativeKitException(meaning(status, diagnostic, invalidArgument), operation, status.rawValue);
	}

	/** The `NativeKitError` the failure `status` is; a mistake of the program's throws its `BindingError`. */
	public static function error(status:NativeResult, operation:String, diagnostic:Null<String>,
			invalidArgument:InvalidArgumentMeans = Misuse):NativeKitError {
		var mistake = misuse(status, invalidArgument);
		if (mistake != null)
			throw new BindingError(mistake, operation, explanation(status, diagnostic));
		return meaning(status, diagnostic, invalidArgument);
	}

	static function misuse(status:NativeResult, invalidArgument:InvalidArgumentMeans):Null<BindingErrorKind>
		return switch status {
			case NativeResult.ErrorInvalidArgument: invalidArgument == Misuse ? InvalidArgument : null;
			case NativeResult.ErrorBufferTooSmall: InvalidArgument;
			case NativeResult.ErrorInvalidHandle: Disposed;
			case NativeResult.ErrorWrongThread, NativeResult.ErrorNotInitialized, NativeResult.ErrorAlreadyInitialized,
				NativeResult.ErrorInvalidRequest: InvalidState;
			case _: null;
		}

	static function meaning(status:NativeResult, diagnostic:Null<String>,
			invalidArgument:InvalidArgumentMeans):NativeKitError {
		var reason = diagnostic == null ? "" : diagnostic;
		return switch status {
			case NativeResult.ErrorInvalidArgument: invalidArgument == MissingPath ? NotFound : InvalidData(reason);
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
			case NativeResult.HttpDns, NativeResult.TransportDns: HostNotFound;
			case NativeResult.HttpConnection, NativeResult.TransportConnection: ConnectionFailed(reason);
			case NativeResult.HttpTimeout, NativeResult.TransportTimeout: TimedOut;
			case NativeResult.HttpTls: TlsFailed(reason);
			case NativeResult.HttpProtocol, NativeResult.TransportProtocol: ProtocolViolation(reason);
			case NativeResult.TransportClosed: Closed;
			case NativeResult.TransportAddressInUse: AddressInUse;
			case NativeResult.HttpRedirect: TooManyRedirects;
			case NativeResult.HttpProxy: ProxyFailed(reason);
			case _: Failed(status.rawValue, reason);
		}
	}

	static function explanation(status:NativeResult, diagnostic:Null<String>):String
		return diagnostic == null || diagnostic.length == 0 ? 'NativeKit result ${status.rawValue}'
			: '$diagnostic (NativeKit result ${status.rawValue})';
}
