enum Payload<T> {
	Empty;
	Code(value:Int);
	Item(value:T);
	Items(values:Array<T>);
}

typedef Wrapped<T> = Payload<T>;

struct Pair {
	public var count:Int;
	public var label:String;
	public function new(count:Int, label:String) { this.count = count; this.label = label; }
}

class Factory<T> {
	var value:T;
	public function new(value:T) this.value = value;
	public function make():Dynamic { var result:Payload<T> = Item(value); return result; }
}

function make<T>(value:T):Dynamic { var result:Payload<T> = Item(value); return result; }
function makeWrapped<T>(value:T):Dynamic { var result:Wrapped<T> = Item(value); return result; }
function later<T>(value:T):Void->Dynamic return () -> { var result:Payload<T> = Item(value); return result; };

function erasedString(value:Dynamic):Bool {
	var typed:Payload<String> = cast value;
	return switch typed { case Item(text): text == "text"; default: false; };
}

function codes(value:Payload<Int>):Array<Int> {
	var result = [];
	switch value { case Code(code): result.push(code); default: }
	return result;
}

function main():Int {
	var text:Payload<String> = Item("text"), number:Payload<Int> = Code(42);
	if ((switch text { case Item(value): value; default: "wrong"; }) != "text") return 1;
	if ((switch number { case Code(value): value; default: 0; }) != 42) return 2;
	var values:Array<Payload<Pair>> = [Item(new Pair(39, "abc")), Empty];
	var score = 0;
	for (value in values.iterator()) switch value {
		case Item(pair): score += pair.count + pair.label.length;
		case Empty:
		default: return 3;
	}
	if (score != 42) return 4;
	var items:Payload<Int> = Items([19, 23]);
	if ((switch items { case Items(array): array[0] + array[1]; default: 0; }) != 42) return 5;
	if (!erasedString(make("text"))) return 6;
	if (!erasedString(new Factory("text").make())) return 7;
	var get = later("text");
	if (!erasedString(get())) return 8;
	if (!erasedString(makeWrapped("text"))) return 9;
	if (codes(number)[0] != 42) return 10;
	return 42;
}
