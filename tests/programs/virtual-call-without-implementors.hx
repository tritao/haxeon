// An interface method that no class in the program implements still type-checks at its call sites.
// The Wasm backends lower such a call to a trap followed by the code that would use its result.
interface Parser {
	function parse(text:String):Null<Dynamic>;
}

enum Parsed {
	Missing;
	Value(data:Dynamic);
}

class Registry {
	final parsers:Map<String, Parser> = [];

	public function new() {}

	public function parse(typeId:String, text:String):Parsed {
		var parser = parsers.get(typeId);
		if (parser == null)
			return Missing;
		var data = parser.parse(text + "!");
		return data == null ? Missing : Value(data);
	}
}

function main():Int {
	return switch new Registry().parse("upper", "ok") {
		case Missing: 42;
		case Value(_): 1;
	};
}
