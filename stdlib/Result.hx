/**
 * The outcome of an operation whose failure its caller is meant to handle: the value, or an error naming the failure.
 * `E` is an error enum whose cases carry their data, so a `switch` over it is exhaustive. A failure that is a bug throws
 * instead. A result must be used (`MustUse`): `_ = result;` drops one on purpose.
 */
enum Result<T, E> implements MustUse {
	/** The operation succeeded with `value`. */
	Ok(value:T);

	/** The operation failed with `error`. */
	Err(error:E);

	/** Whether this is an `Ok`. */
	public function isOk():Bool
		return switch this {
			case Ok(_): true;
			case Err(_): false;
		}

	/** Whether this is an `Err`. */
	public function isErr():Bool
		return !isOk();

	/** The value transformed by `f`, or the same error. */
	public function map<U>(f:T->U):Result<U, E>
		return switch this {
			case Ok(value): Ok(f(value));
			case Err(error): Err(error);
		}

	/**
	 * The error transformed by `f`, or the same value. A case constructor serves as `f` to wrap one error type in
	 * another: `read(path).mapErr(ConfigError.Unreadable)`.
	 */
	public function mapErr<F>(f:E->F):Result<T, F>
		return switch this {
			case Ok(value): Ok(value);
			case Err(error): Err(f(error));
		}

	/** The result of `f` on the value, or the same error: a second operation that runs only when this one succeeded. */
	public function andThen<U>(f:T->Result<U, E>):Result<U, E>
		return switch this {
			case Ok(value): f(value);
			case Err(error): Err(error);
		}

	/** The value, or `fallback` for an error. */
	public function unwrapOr(fallback:T):T
		return switch this {
			case Ok(value): value;
			case Err(_): fallback;
		}

	/** The value. Throws for an error, so a caller that writes it says a failure here is a bug. */
	public function unwrap():T
		return switch this {
			case Ok(value): value;
			case Err(error): throw new haxe.Exception("unwrap() of Err(" + Std.string(error) + ")");
		}
}
