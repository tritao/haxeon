class BaseValue {
	public function new() {}

	public function value():Int
		return 1;
}

class DerivedValue extends BaseValue {
	public function new() {
		super();
	}

	override public function value():Int
		return 42;
}

function main():Int {
	var value:BaseValue = new DerivedValue();
	return value.value();
}
