package haxe;

#if wasm
// Wasm has no runtime symbolizer yet, so stacks are empty.
function nativeExceptionStack():Array<String>
	return [];

function nativeCallStack():Array<String>
	return [];
#else
@:hlNative("haxeon_runtime", "__exception_stack")
extern function nativeExceptionStack():Array<String>;

@:hlNative("haxeon_runtime", "__call_stack")
extern function nativeCallStack():Array<String>;
#end

/** One portable call-stack entry. */
enum StackItem {
	CFunction;
	Module(module:String);
	FilePos(item:Null<StackItem>, file:String, line:Int, ?column:Int);
	Method(className:Null<String>, method:String);
	LocalFunction(?index:Int);
}

/**
	A call-stack snapshot, innermost frame first, as on Haxe's HashLink target: each frame is a
	`FilePos(Method(className, method), file, line)`, or a `Module(symbol)` for a frame whose symbol does not name a method.
**/
class CallStack {
	public var length(get, never):Int;

	final items:Array<StackItem>;

	public function new(?items:Array<StackItem>) {
		this.items = items == null ? [] : items;
	}

	function get_length():Int
		return items.length;

	/**
		The frames calling the function that calls this one (Haxe's `CallStack.callStack()`), without the program's entry.
		This function's own frame, the stack's first, is left out; it must stay a frame of its own, which its loop sees to:
		the inliner splices only straight-line bodies, and inlined, the caller's frame would read this file's position.
	**/
	public static function callStack():CallStack {
		var symbols = nativeCallStack();
		return new CallStack([for (index in 1...symbols.length - 1) frame(symbols[index])]);
	}

	/** The frames calling an exception's constructor, as Haxe's HL std records for `new Exception(...)`. */
	@:noCompletion public static function constructorStack():CallStack {
		// Haxe leaves out the constructors of the exception's subclasses too (each `super` call shifts the stack): the
		// constructors run directly after haxe.Exception's.
		var symbols = nativeCallStack(),
			start = symbols.length;
		for (index in 0...symbols.length)
			if (StringTools.startsWith(symbols[index], "haxe.Exception.new(")) {
				start = index + 1;
				break;
			}
		while (start < symbols.length - 1 && symbols[start].indexOf(".new(") > 0)
			start++;
		return frames(symbols, start);
	}

	/** The frames of the last exception thrown, from the throw outwards. */
	public static function exceptionStack(?fullStack:Bool = false):CallStack
		return frames(nativeExceptionStack(), 0);

	/** `\nCalled from <item>` for each item, as Haxe prints a stack. */
	public static function toString(stack:CallStack):String {
		var buffer = new StringBuf();
		for (item in stack.items) {
			buffer.add("\nCalled from ");
			itemToString(buffer, item);
		}
		return buffer.toString();
	}

	/** The frames `symbols` names from `start` on, without the program's entry (the last), as Haxe's HL std reads them. */
	static function frames(symbols:Array<String>, start:Int):CallStack {
		var items:Array<StackItem> = [];
		for (index in start...symbols.length - 1)
			items.push(frame(symbols[index]));
		return new CallStack(items);
	}

	/** A HashLink frame symbol, `Class.method(file:line)`, as a stack item. */
	static function frame(symbol:String):StackItem {
		var open = symbol.lastIndexOf("("),
			colon = symbol.lastIndexOf(":");
		if (open > 0 && colon > open && StringTools.endsWith(symbol, ")")) {
			var name = symbol.substring(0, open),
				file = symbol.substring(open + 1, colon),
				line = Std.parseInt(symbol.substring(colon + 1, symbol.length - 1)),
				dot = name.lastIndexOf(".");
			if (line != null && dot > 0)
				return FilePos(Method(name.substring(0, dot), name.substring(dot + 1)), file, line);
		}
		return Module(symbol);
	}

	static function itemToString(buffer:StringBuf, item:StackItem):Void {
		switch item {
			case CFunction:
				buffer.add("a C function");
			case Module(module):
				buffer.add("module ");
				buffer.add(module);
			case FilePos(inner, file, line, column):
				if (inner != null) {
					itemToString(buffer, inner);
					buffer.add(" (");
				}
				buffer.add(file);
				buffer.add(" line ");
				buffer.add(line);
				if (column != null) {
					buffer.add(" column ");
					buffer.add(column);
				}
				if (inner != null)
					buffer.add(")");
			case Method(className, method):
				buffer.add(className == null ? "<unknown>" : className);
				buffer.add(".");
				buffer.add(method);
			case LocalFunction(index):
				buffer.add("local function #");
				buffer.add(index);
		}
	}

	public function asArray():Array<StackItem>
		return items;

	public function iterator():Iterator<StackItem>
		return items.iterator();

	public function copy():CallStack
		return new CallStack(items.copy());

	/**
		This stack without its frames from the first run it shares with `stack` on: what a chained exception's stack adds to
		the stack of the exception before it (Haxe's `CallStack.subtract`).
	**/
	@:noCompletion public function subtract(stack:CallStack):CallStack {
		var startIndex = -1,
			i = -1,
			other = stack.items;
		while (++i < items.length) {
			for (j in 0...other.length) {
				if (equalItems(items[i], other[j])) {
					if (startIndex < 0)
						startIndex = i;
					++i;
					if (i >= items.length)
						break;
				} else
					startIndex = -1;
			}
			if (startIndex >= 0)
				break;
		}
		return startIndex >= 0 ? new CallStack(items.slice(0, startIndex)) : this;
	}

	static function equalItems(left:Null<StackItem>, right:Null<StackItem>):Bool {
		if (left == null || right == null)
			return left == null && right == null;
		return switch [left, right] {
			case [CFunction, CFunction]: true;
			case [Module(a), Module(b)]: a == b;
			case [FilePos(itemA, fileA, lineA, columnA), FilePos(itemB, fileB, lineB, columnB)]:
				fileA == fileB && lineA == lineB && columnA == columnB && equalItems(itemA, itemB);
			case [Method(classA, methodA), Method(classB, methodB)]: classA == classB && methodA == methodB;
			case [LocalFunction(a), LocalFunction(b)]: a == b;
			default: false;
		};
	}
}
