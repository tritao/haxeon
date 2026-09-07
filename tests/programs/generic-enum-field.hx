enum Instruction {
	Constant(value:Int);
}

class Located<T> {
	public final value:T;

	public function new(value:T) {
		this.value = value;
	}
}

function main():Int {
	var located = new Located(Instruction.Constant(42));
	return switch located.value {
		case Constant(value): value;
	};
}
