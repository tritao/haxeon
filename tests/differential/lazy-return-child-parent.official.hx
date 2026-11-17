class Parent {
	public function new() {}
}

class Child extends Parent {
	public function new() {
		super();
	}
}

class Main {
	static function make(flag:Bool) {
		if (flag)
			return new Child();
		return new Parent();
	}

	static function main() {
		make(true);
	}
}
