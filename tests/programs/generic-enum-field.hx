enum Instruction {
	Ready;
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
	var ready = new Located(Instruction.Ready);
	return switch located.value {
		case Constant(value):
			switch ready.value {
				case Ready: value;
				case Constant(_): 0;
			}
		case Ready: 0;
	};
}
