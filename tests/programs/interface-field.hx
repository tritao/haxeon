interface ValueSource {
	function value():Int;
}

class ConstantSource implements ValueSource {
	public function new() {}
	public function value():Int return 42;
}

class Holder {
	public final source:ValueSource;
	public function new(source:ValueSource) {
		this.source = source;
	}
}

function main():Int {
	return new Holder(new ConstantSource()).source.value();
}
