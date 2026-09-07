package haxe;

/** Exception wrapper retaining an arbitrary thrown value. */
class ValueException extends Exception {
	public var value(default, null):Dynamic;

	public function new(value:Dynamic, ?previous:Exception, ?native:Dynamic) {
		super(Std.string(value), previous, native);
		this.value = value;
	}

	override public function unwrap():Dynamic
		return value;
}
