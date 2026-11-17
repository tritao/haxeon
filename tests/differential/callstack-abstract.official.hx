// haxe.CallStack is Haxe's abstract over Array<StackItem>: an exception's stack indexes and has a length, and CallStack's
// functions return arrays a stack is made from.
import haxe.CallStack;

class Fail extends haxe.Exception {}

class Main {
	static function inner():Void
		throw new Fail("boom");

	static function main() {
		try
			inner()
		catch (e:Fail) {
			var stack = e.stack;
			Sys.println(stack.length > 0);
			Sys.println(Std.string(stack[0]).indexOf("inner") >= 0);
			var count = 0;
			for (i in 0...stack.length)
				if (stack[i] != null)
					count++;
			Sys.println(count == stack.length);
			var arr:Array<StackItem> = CallStack.callStack();
			Sys.println(arr.length > 0);
			Sys.println(CallStack.toString(CallStack.exceptionStack()).indexOf("Called from") >= 0);
			Sys.println(e.details().indexOf("Exception: boom") == 0);
		}
	}
}
