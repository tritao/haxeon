struct Cell implements Hashable {
	public var row:Int;
	public var column:Int;

	public function new(row:Int, column:Int) {
		this.row = row;
		this.column = column;
	}
}

function main():Void {
	final original = new Cell(2, 5);
	var copy = original;
	copy.column = 6;
	Sys.println(original.column);
	Sys.println(copy == original);
	final names:Map<Cell, String> = [original => "start"];
	Sys.println(names.get(new Cell(2, 5)) ?? "missing");
}
