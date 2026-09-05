class Point {
	public var value:Int = 40;

	public function new():Void {
		this.value = this.value + 1;
	}
}

function main():Int {
	return new Point().value + 1;
}
