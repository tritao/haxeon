package haxeon.wire;

/**
 * Why wire input could not be decoded, in MessagePack or JSON: what `MessagePack.decode`, `JsonWire.decode` and the frame
 * and schema readers return as their `Err`. Input that comes from outside the program can be any of these, so a caller
 * handles them; a misused reader or writer (a negative limit, a null value) throws instead.
 */
enum WireError {
	/** The input ends inside a value. */
	Truncated;

	/** Another value follows the one decoded, where the input must hold exactly one. */
	TrailingData;

	/** The input is not the format, or not the shape the decoded type expects there: `reason` says what was found. */
	Malformed(reason:String);

	/** The input, a container in it, or its nesting is larger than the configured limit `reason` names. */
	LimitExceeded(reason:String);

	/** A writer's schema descriptor is missing, damaged, or does not fit the type being decoded. */
	IncompatibleSchema(reason:String);
}
