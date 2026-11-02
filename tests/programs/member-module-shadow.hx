function value():Int return 100;
function get():Int return 100;

class Base {
	public var value:Int;
	public function new() value = 20;
	public function get():Int return value + 1;
}

struct Point {
	public var value:Int;
	public function new(value:Int) this.value = value;
	public function read():Int return value;
}

class Child extends Base {
	public function new() super();
	public function read():Int return value + get() + new Point(1).read();
}

function main():Int return new Child().read();
