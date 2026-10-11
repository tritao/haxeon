@:value class Padding {
	public final bottom:Float;

	public function new(seed:Int)
		bottom = seed + 4.0;
}

@:value class Nested {
	public final padding:Padding;
	public final tag:Int;

	public function new(seed:Int) {
		padding = new Padding(seed);
		tag = seed;
	}
}

class Retained {
	public static var rows:Array<Nested> = [];
}

function main():Int {
	for (i in 0...1000) {
		var row = new Nested(i);
		Retained.rows.push(row);
	}
	for (i in 0...1000) {
		if (Retained.rows[i].tag != i)
			return 51;
		if (Retained.rows[i].padding.bottom != i + 4)
			return 52;
	}
	hl.Gc.major();
	for (i in 0...1000) {
		if (Retained.rows[i].tag != i)
			return 61;
		if (Retained.rows[i].padding.bottom != i + 4)
			return 62;
	}
	return 42;
}
