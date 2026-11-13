// A struct that is only the element type of a field of a class nothing constructs, in a program that compares Dynamic values: the Dynamic equality
// dispatcher must name only the structs reached code can have, and every class it does name must be in the module written for the build.
private struct NeverBuilt {
	public final id:Int;
	public final x:Float;
	public function new(id:Int, x:Float) {
		this.id = id;
		this.x = x;
	}
}

class NeverHolder {
	final items:Array<NeverBuilt> = [];
	public function new() {}
	public function count():Int return items.length;
}

function main():Int {
	var left:Dynamic = 21;
	var right:Dynamic = 21;
	return left == right ? 42 : 0;
}
