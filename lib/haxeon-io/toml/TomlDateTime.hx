package toml;

/** Which of TOML's four date and time types a `TomlDateTime` is. */
enum TomlDateTimeKind {
	/** `1979-05-27T07:32:00Z`, `1979-05-27 00:32:00.999-07:00`: an instant. */
	OffsetDateTime;

	/** `1979-05-27T07:32:00`: a date and time in no particular zone. */
	LocalDateTime;

	/** `1979-05-27`. */
	LocalDate;

	/** `07:32:00.5`. */
	LocalTime;
}

/**
 * A TOML date or time, kept as the text the document wrote (validated, never normalized), so it prints back unchanged. Converting it to
 * a `Date` is the reader's choice, as a local date or time has no instant.
 */
class TomlDateTime {
	/** Which of the four types it is. */
	public final kind:TomlDateTimeKind;

	/** The text the document wrote. */
	public final text:String;

	/** A date or time of `kind` written as `text`, which must be valid for it. */
	public function new(kind:TomlDateTimeKind, text:String) {
		this.kind = kind;
		this.text = text;
	}

	/** The text the document wrote. */
	public function toString():String
		return text;
}
