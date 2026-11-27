package haxe;

#if wasm
/** A stack taken and not yet named: always empty on Wasm, which has no runtime symbolizer yet. */
typedef StackFrames = Array<String>;
#else

/**
	A stack taken and not yet named: naming a frame resolves its symbol, most of what a stack costs, so haxe.Exception takes
	one each time it is made and names it only when its `stack` is read.
**/
typedef StackFrames = hl.Bytes;
#end

/** One portable call-stack entry. */
enum StackItem {
	/** A frame of native code. */
	CFunction;

	/** A frame named only by its symbol, `module`, which names no method. */
	Module(module:String);

	/** A frame at `line` (and `column`) of `file`, in `item`: the method or function the code is in, when known. */
	FilePos(item:Null<StackItem>, file:String, line:Int, ?column:Int);

	/** The method `method` of the class `className`; null for a module-level function. */
	Method(className:Null<String>, method:String);

	/** A local function, the `index`th of its method. */
	LocalFunction(?index:Int);
}

/**
	A call-stack snapshot, innermost frame first, as on Haxe's HashLink target: each frame is a
	`FilePos(Method(className, method), file, line)`, or a `Module(symbol)` for a frame whose symbol does not name a method.
	As in Haxe, it is an abstract over its items: `stack[i]`, `stack.length`, and an `Array<StackItem>` where a stack is
	expected.
**/
@:arrayAccess
abstract CallStack(Array<StackItem>) from Array<StackItem> {
	/** The number of frames. */
	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	/**
		The frames calling the function that calls this one (Haxe's `CallStack.callStack()`), without the program's entry.
		This function's own frame, the stack's first, is left out; it must stay a frame of its own, which its loop sees to:
		the inliner splices only straight-line bodies, and inlined, the caller's frame would read this file's position.
	**/
	public static function callStack():Array<StackItem> {
		var symbols = nativeCallStack();
		return [for (index in 1...symbols.length - 1) frame(symbols[index])];
	}

	/**
		The frames calling an exception's constructor, as Haxe's HL std records for `new Exception(...)`, from the frames
		haxe.Exception's constructor took (`callStackFrames`).
	**/
	@:noCompletion public static function constructorStack(taken:StackFrames):CallStack {
		// Haxe leaves out the constructors of the exception's subclasses too (each `super` call shifts the stack): the
		// constructors run directly after haxe.Exception's.
		var symbols = stackFrameSymbols(taken),
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
	public static function exceptionStack(?fullStack:Bool = false):Array<StackItem>
		return frames(nativeExceptionStack(), 0);

	/** The frames of the last throw, or else the frames now on the stack, taken for an exception to name later. */
	@:noCompletion public static function takeFrames(fromThrow:Bool):StackFrames
		return fromThrow ? exceptionStackFrames() : callStackFrames();

	/** The frames of a throw, from frames `exceptionStackFrames` took. */
	@:noCompletion public static function thrownStack(taken:StackFrames):CallStack
		return frames(stackFrameSymbols(taken), 0);

	#if wasm
	static function nativeExceptionStack():Array<String>
		return [];

	static function nativeCallStack():Array<String>
		return [];

	static function callStackFrames():StackFrames
		return [];

	static function exceptionStackFrames():StackFrames
		return [];

	static function stackFrameSymbols(frames:StackFrames):Array<String>
		return frames;
	#else
	@:hlNative("haxeon_runtime", "__exception_stack")
	static extern function nativeExceptionStack():Array<String>;

	@:hlNative("haxeon_runtime", "__call_stack")
	static extern function nativeCallStack():Array<String>;

	/** The frames now on the stack, innermost first, unnamed. */
	@:hlNative("haxeon_runtime", "__call_stack_frames")
	static extern function callStackFrames():StackFrames;

	/** The frames of the last throw, unnamed. */
	@:hlNative("haxeon_runtime", "__exception_stack_frames")
	static extern function exceptionStackFrames():StackFrames;

	/** The symbols of frames `callStackFrames` or `exceptionStackFrames` took, as `nativeCallStack` names them. */
	@:hlNative("haxeon_runtime", "__stack_frame_symbols")
	static extern function stackFrameSymbols(frames:StackFrames):Array<String>;
	#end

	/** `\nCalled from <item>` for each item, as Haxe prints a stack. */
	public static function toString(stack:CallStack):String {
		var buffer = new StringBuf();
		for (item in stack.asArray()) {
			buffer.add("\nCalled from ");
			itemToString(buffer, item);
		}
		return buffer.toString();
	}

	/** The frames `symbols` names from `start` on, without the program's entry (the last), as Haxe's HL std reads them. */
	static function frames(symbols:Array<String>, start:Int):Array<StackItem>
		return [for (index in start...symbols.length - 1) frame(symbols[index])];

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

	/** The stack's items, the array it is. */
	public function asArray():Array<StackItem>
		return this;

	/** The items, innermost frame first. */
	public function iterator():Iterator<StackItem>
		return this.iterator();

	/** A copy of the stack, with its own array of items. */
	public function copy():CallStack
		return this.copy();

	/**
		This stack without its frames from the first run it shares with `stack` on: what a chained exception's stack adds to
		the stack of the exception before it (Haxe's `CallStack.subtract`).
	**/
	@:noCompletion public function subtract(stack:CallStack):CallStack {
		var startIndex = -1,
			i = -1,
			items = this,
			other = stack.asArray();
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
		return startIndex >= 0 ? items.slice(0, startIndex) : items;
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
