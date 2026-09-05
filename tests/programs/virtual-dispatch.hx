class Base {
	public function first():Int {
		return 10;
	}

	public function second():Int {
		return 20;
	}
}

class Child extends Base {
	public function third():Int {
		return 30;
	}

	public function first():Int {
		return 21;
	}
}

function main():Int {
	var value = new Child();
	return value.first() + value.second() + value.third();
}
