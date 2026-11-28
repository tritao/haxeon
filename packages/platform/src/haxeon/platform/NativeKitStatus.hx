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
	public static function failure(status:NativeResult, operation:String, diagnostic:Null<String>):PlatformError
		return switch classify(status, diagnostic) {
			case Mistake(kind): new BindingError(kind, operation, explanation(status, diagnostic));
			case Answer(error): new NativeKitException(error, operation, status.rawValue);
		};

	/** The `NativeKitError` the failure `status` is; a mistake of the program's throws its `BindingError`. */
	public static function error(status:NativeResult, operation:String, diagnostic:Null<String>):NativeKitError
		return switch classify(status, diagnostic) {
			case Mistake(kind): throw new BindingError(kind, operation, explanation(status, diagnostic));
			case Answer(error): error;
		};

	/**
	 * The `NativeKitError` a failure `status` reported by an event is. An event has no call to throw from, so a code
	 * that would be the program's mistake is `Failed(code, reason)` here rather than a `BindingError`.
	 */
	public static function reported(status:NativeResult, diagnostic:Null<String>):NativeKitError
		return switch classify(status, diagnostic) {
			case Mistake(_): Failed(status.rawValue, explanation(status, diagnostic));
			case Answer(error): error;
		};

	/**
	 * Which kind of failure `status` is. The switch names every NativeKit code and has no default, so a code NativeKit
	 * adds fails to build here until it is classified.
	 */
	static function classify(status:NativeResult, diagnostic:Null<String>):StatusMeaning {
		var reason = diagnostic == null ? "" : diagnostic;
		return switch status {
			case NativeResult.Ok, NativeResult.Pending:
				throw BindingError.invalidState("NativeKitStatus.classify",
					'NativeKit result ${status.rawValue} is not a failure');
			case NativeResult.ErrorInvalidArgument, NativeResult.ErrorBufferTooSmall: Mistake(InvalidArgument);
			case NativeResult.ErrorInvalidHandle: Mistake(Disposed);
			case NativeResult.ErrorWrongThread, NativeResult.ErrorNotInitialized, NativeResult.ErrorAlreadyInitialized,
				NativeResult.ErrorInvalidRequest:
				Mistake(InvalidState);
			case NativeResult.ErrorInvalidData: Answer(InvalidData(reason));
			case NativeResult.ErrorUnsupported: Answer(Unsupported(reason));
			case NativeResult.ErrorNotFound: Answer(NotFound);
			case NativeResult.ErrorPermissionDenied: Answer(PermissionDenied(reason));
			case NativeResult.ErrorCancelled, NativeResult.HttpCanceled,
				NativeResult.TransportCanceled: Answer(Cancelled);
			case NativeResult.ErrorQueueFull, NativeResult.HttpWouldBlock,
				NativeResult.TransportWouldBlock: Answer(Busy);
			case NativeResult.ErrorPayloadTooLarge, NativeResult.HttpResponseLimit,
				NativeResult.TransportReceiveOverflow:
				Answer(TooLarge);
			case NativeResult.ErrorOutOfMemory: Answer(OutOfMemory);
			case NativeResult.ErrorSurfaceLost: Answer(SurfaceLost);
			case NativeResult.HttpDns, NativeResult.TransportDns: Answer(Network(HostNotFound));
			case NativeResult.HttpConnection,
				NativeResult.TransportConnection: Answer(Network(ConnectionFailed(reason)));
			case NativeResult.HttpTimeout, NativeResult.TransportTimeout: Answer(Network(TimedOut));
			case NativeResult.HttpTls: Answer(Network(TlsFailed(reason)));
			case NativeResult.HttpProtocol, NativeResult.TransportProtocol: Answer(Network(ProtocolViolation(reason)));
			case NativeResult.TransportClosed: Answer(Network(Closed));
			case NativeResult.TransportAddressInUse: Answer(Network(AddressInUse));
			case NativeResult.HttpRedirect: Answer(Network(TooManyRedirects));
			case NativeResult.HttpProxy: Answer(Network(ProxyFailed(reason)));
			case NativeResult.ErrorUnknown: Answer(Failed(status.rawValue, reason));
		};
	}

	static function explanation(status:NativeResult, diagnostic:Null<String>):String
		return diagnostic == null || diagnostic.length == 0 ? 'NativeKit result ${status.rawValue}'
			: '$diagnostic (NativeKit result ${status.rawValue})';
}

/** A failing NativeKit code's kind: the program's mistake, or the environment's answer. */
private enum StatusMeaning {
	Mistake(kind:BindingErrorKind);
	Answer(error:NativeKitError);
}
