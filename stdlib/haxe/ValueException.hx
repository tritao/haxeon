package haxe;

/** The exception a catch of `haxe.Exception` sees when the thrown value is not an exception: it wraps that value. */
class ValueException extends Exception {
	/** The value that was thrown. */
	public var value(default, null):Dynamic;

	/** An exception wrapping `value`, whose message is `Std.string(value)`. */
	public function new(value:Dynamic, ?previous:Exception, ?native:Dynamic) {
		super(Std.string(value), previous, native);
		this.value = value;
	}

	override public function unwrap():Dynamic
		return value;
}
