// Metadata on a statement changes nothing it compiles to: an annotated block is a block statement (here one that returns on
// every path), and an annotated local declaration declares the local.
class Holder {
	public var value:Null<String> = null;
	public function new() {}
}
function describe(h:Holder):String {
	@:privateAccess {
		var v = h.value;
		if (v == null)
			return "none";
		return 'value $v';
	}
}
function plain(h:Holder):String {
	{
		var v = h.value;
		if (v == null)
			return "none";
		return 'value $v';
	}
}
function main():Int return describe(new Holder()) == "none" && plain(new Holder()) == "none"
	&& annotatedVar() == 42 ? 42 : 1;
function annotatedVar():Int {
	@:keep var x = 41;
	return x + 1;
}
