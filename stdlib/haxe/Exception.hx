package haxe;

/** Base class for source-level exceptions. */
class Exception {
	public var message(default, null):String;
	public var stack(default, null):CallStack;
	public var previous(default, null):Null<Exception>;
	public var native(default, null):Dynamic;

	public function new(message:String, ?previous:Exception, ?native:Dynamic) {
		this.message = message;
		this.previous = previous;
		this.native = native == null ? this : native;
		stack = CallStack.callStack();
	}

	public function unwrap():Dynamic
		return native;

	public function toString():String
		return message;

	public function details():String
		return message + CallStack.toString(stack);
}
