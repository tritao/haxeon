package haxe;

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
		return new CallStack();

	public static function toString(stack:CallStack):String
		return "";

	public function copy():CallStack
		return new CallStack(items.copy());
}
