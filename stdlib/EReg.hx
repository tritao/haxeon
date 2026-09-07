/** Match coordinates returned by {@link EReg.matchedPos}. */
typedef ERegMatch = {
	final pos:Int;
	final len:Int;
}

/** Regular-expression compatibility subset with deterministic match state. */
class EReg {
	final pattern:String;
	final options:String;
	var input = "";
	var position = -1;

	public function new(pattern:String, options:String) {
		this.pattern = pattern;
		this.options = options;
	}

	public function match(value:String):Bool {
		input = value;
		position = options.indexOf("i") < 0 ? value.indexOf(pattern) : value.toLowerCase().indexOf(pattern.toLowerCase());
		return position >= 0;
	}

	public function matched(index:Int):String
		return index == 0 && position >= 0 ? input.substr(position, pattern.length) : "";

	public function matchedLeft():String
		return position < 0 ? "" : input.substr(0, position);

	public function matchedRight():String
		return position < 0 ? "" : input.substr(position + pattern.length);

	public function matchedPos():ERegMatch
		return {pos: position, len: position < 0 ? 0 : pattern.length};

	public function replace(value:String, by:String):String {
		var result = "", remaining = value, global = options.indexOf("g") >= 0;
		while (match(remaining)) {
			result += matchedLeft() + by;
			remaining = matchedRight();
			if (!global)
				break;
		}
		return result == "" ? value : result + remaining;
	}

	public function split(value:String):Array<String>
		return value.split(pattern);
}
