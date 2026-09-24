package haxe;

@:hlNative("std", "exception_stack")
extern function nativeExceptionStack():Array<String>;

/** One portable call-stack entry. */
enum StackItem {
	CFunction;
	Module(module:String);
	FilePos(item:Null<StackItem>, file:String, line:Int, ?column:Int);
	Method(className:Null<String>, method:String);
	LocalFunction(?index:Int);
}

/** Portable call-stack snapshot for the currently supported runtime subset. */
class CallStack {
	public var length(get, never):Int;

	final items:Array<StackItem>;

	public function new(?items:Array<StackItem>) {
		this.items = items == null ? [] : items;
	}

	function get_length():Int
		return items.length;

	public static function callStack():CallStack
		return new CallStack();

	public static function exceptionStack(?fullStack:Bool = false):CallStack
		return new CallStack([for (symbol in nativeExceptionStack()) Module(symbol)]);

	public static function toString(stack:CallStack):String {
		var lines:Array<String> = [];
		for (item in stack.items) {
			var line = switch (item) {
				case Module(module): module;
				case Method(className, method): (className == null ? "" : className + ".") + method;
				case FilePos(_, file, line, column): file + ":" + line;
				case LocalFunction(index): "local function";
				case CFunction: "native function";
			};
			lines.push("Called from " + line);
		}
		return lines.join("\n");
	}

	public function copy():CallStack
		return new CallStack(items.copy());
}
