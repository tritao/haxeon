package haxe;

/**
	Base class for source-level exceptions.

	As on Haxe's HashLink target, `throw` throws a value as it is, and a catch clause wraps or unwraps it: a catch of
	`haxe.Exception` or a subclass tests `caught(thrown)`, a catch of any other type tests `caughtValue(thrown)`, and
	`catch (e:Dynamic)` binds the thrown value itself (the compiler's `TypedCatchSubject`).
**/
class Exception {
	public var message(default, null):String;
	public var stack(default, null):CallStack;
	public var previous(default, null):Null<Exception>;
	public var native(default, null):Dynamic;

	/** The thrown exception, or a `haxe.ValueException` wrapping a thrown value that is no exception. */
	@:noCompletion static function caught(value:Dynamic):Exception {
		if (Std.isOfType(value, Exception))
			return (value:Exception);
		return new ValueException(value, null, value);
	}

	/** The value a catch of a type outside `haxe.Exception` tests: `caught(value).unwrap()`, without wrapping a value first. */
	@:noCompletion static function caughtValue(value:Dynamic):Dynamic {
		if (Std.isOfType(value, Exception))
			return (value:Exception).unwrap();
		return value;
	}

	public function new(message:String, ?previous:Exception, ?native:Dynamic) {
		this.message = message;
		this.previous = previous;
		// An exception made for a value already thrown (`caught`) carries the stack of that throw.
		if (native == null) {
			this.native = this;
			stack = CallStack.callStack();
		} else {
			this.native = native;
			stack = CallStack.exceptionStack();
		}
	}

	public function unwrap():Dynamic
		return native;

	public function toString():String
		return message;

	public function details():String
		return message + CallStack.toString(stack);
}
