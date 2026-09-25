class Shape {
	public function new() {}

	public function scale(factor:Int):Int
		return factor * unit();

	public function unit():Int
		return 1;
}

class Square extends Shape {
	public function new()
		super();

	override public function unit():Int
		return 10;
}

class Tile extends Square {
	public function new()
		super();

	// Square does not override scale; super.scale reaches Shape.scale, whose unit() still dispatches.
	override public function scale(factor:Int):Int
		return super.scale(factor) + 1;

	override public function unit():Int
		return super.unit() + 2;
}

function main():Int {
	var tile:Shape = new Tile();
	return tile.scale(3) == 37 && tile.unit() == 12 && new Square().scale(2) == 20 ? 42 : 1;
}
