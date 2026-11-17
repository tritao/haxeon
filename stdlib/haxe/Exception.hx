package haxe;

/**
	Base class for source-level exceptions.

	As on Haxe's HashLink target, `throw` throws a value as it is, and a catch clause wraps or unwraps it: a catch of
	`haxe.Exception` or a subclass tests `caught(thrown)`, a catch of any other type tests `caughtValue(thrown)`, and
	`catch (e:Dynamic)` binds the thrown value itself (the compiler's `TypedCatchSubject`).
**/
class Exception {
	public var message(default, null):String;
	public var stack(get, null):CallStack;
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

	/**
		The frames taken when this exception was made, until `stack` names them: the frames calling the constructor, or for an
		exception made for a value already thrown (`caught`), the frames of that throw (`fromThrow`).
	**/
	var stackFrames:Null<CallStack.StackFrames>;

	var fromThrow:Bool;

	/** Making an exception changes nothing anyone can see: it takes the call stack, so construction keeps flow facts. */
	@:pure public function new(message:String, ?previous:Exception, ?native:Dynamic) {
		this.message = message;
		this.previous = previous;
		fromThrow = native != null;
		this.native = native == null ? this : native;
		stackFrames = CallStack.takeFrames(fromThrow);
	}

	/** Names the frames on the first read and keeps the stack: every read sees the same stack, so reading it changes nothing. */
	@:pure function get_stack():CallStack {
		var taken = stackFrames;
		if (taken != null) {
			stack = fromThrow ? CallStack.thrownStack(taken) : CallStack.constructorStack(taken);
			stackFrames = null;
		}
		return stack;
	}

	public function unwrap():Dynamic
		return native;

	public function toString():String
		return message;

	/**
		`Exception: <message>` and the stack, as Haxe prints it; with a chain of `previous` exceptions, each from the first
		thrown on, its stack less the frames it shares with the one before it, joined by `Next`.
	**/
	public function details():String {
		if (previous == null)
			return 'Exception: ${toString()}${CallStack.toString(stack)}';
		var result = "",
			current:Null<Exception> = this,
			after:Null<Exception> = null;
		while (current != null) {
			if (after == null)
				result = 'Exception: ${current.message}${CallStack.toString(current.stack)}' + result;
			else
				result =
					'Exception: ${current.message}${CallStack.toString(current.stack.subtract(after.stack))}\n\nNext '
					+ result;
			after = current;
			current = current.previous;
		}
		return result;
	}
}
