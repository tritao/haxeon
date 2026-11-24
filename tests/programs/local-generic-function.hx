// Exits 42 when local generic calls, captures, recursion and compound types agree.
enum Box<T> {
	Full(value:T);
	Empty;
}

interface Labelled {
	function label():String;
}

class Item implements Labelled {
	public function new() {}

	public function label():String
		return "item";
}

function useInt(f:Int->Int):Int
	return f(42);

function main():Int {
	var calls = 0;
	function pick<T>(a:T, b:T, first:Bool = true):T {
		calls++;
		return first ? a : b;
	}
	var number:Int = pick(42, 0);
	var text:String = pick("first", "second");

	function label<T:Labelled>(value:T):String return value.label();

	function repeat<T>(value:T, depth:Int):T {
		if (depth == 0)
			return value;
		return repeat(value, depth - 1);
	}

	function identity<T>(value:T)
		return value;
	var saved = identity;
	var savedResult:Int = saved(42);
	function wrap<T>(value:T):Box<T>
		return Full(value);
	function unwrap<T>(box:Box<T>, fallback:T):T
		return switch box {
			case Full(value): value;
			case Empty: fallback;
		};
	function boxFirst<T>(values:Array<T>):Box<T>
		return values.length == 0 ? Empty : Full(values[0]);
	function first<T>(values:Array<T>):Null<T>
		return values.length > 0 ? values[0] : null;
	function singleton<T>(value:T):Array<T>
		return [value];
	function apply<T, R>(fn:T->R, value:T):R
		return fn(value);
	function record<T>(input:{value:T}):{value:T} return {value: input.value};
	var wrapInt:Int->Box<Int> = wrap;
	var savedWrap = wrap;
	var savedBox:Box<Int> = savedWrap(42);
	var unknownBox = boxFirst([]);
	var emptyBox:Box<Int> = unknownBox;
	var enumValue = unwrap(wrapInt(42), 0);
	var enumText = unwrap(wrap("enum"), "");
	var empty:Null<Int> = first([]);
	var firstInt:Null<Int> = first(singleton(42));
	var firstText:Null<String> = first(singleton("array"));
	var mapped = apply((s:String) -> s.length, "abc");
	var echoed = apply((n:Int) -> n, 42);
	var field = record({value: 42}).value;
	return enumValue == 42 && unwrap(savedBox, 0) == 42 && unwrap(emptyBox, 42) == 42 && enumText == "enum"
		&& empty == null && firstInt == 42
		&& firstText == "array" && mapped == 3 && echoed == 42 && field == 42
		&& number == 42 && text == "first" && calls == 2 && label(new Item()) == "item"
		&& repeat(42, 2) == 42 && repeat("recursive", 2) == "recursive"
		&& savedResult == 42 && useInt(identity) == 42 ? 42 : 1;
}
