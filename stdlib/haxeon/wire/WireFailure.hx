package haxeon.wire;

/**
 * How a reader, or a codec given to `decodeWith`, fails a decode: it throws one, and the decode returns `error` as its
 * `Err`. Code outside a decode never sees one, since the entry points return a `Result`.
 */
class WireFailure extends haxe.Exception {
	/** Why the input could not be decoded. */
	public final error:WireError;

	/** A failure for `error`, whose message describes it. */
	public function new(error:WireError) {
		super(switch error {
			case Truncated: "Wire input is truncated";
			case TrailingData: "Wire input has trailing data";
			case Malformed(reason), LimitExceeded(reason), IncompatibleSchema(reason): reason;
		});
		this.error = error;
	}

	/** What `decode` gives for `input`, or the error it fails with: the entry points' and the generated decoders' `Result`. */
	@:allow(haxeon.wire)
	static function settle<I, T>(decode:I->T, input:I):Result<T, WireError> {
		try {
			return Ok(decode(input));
		} catch (failure:WireFailure) {
			return Err(failure.error);
		}
	}
}
