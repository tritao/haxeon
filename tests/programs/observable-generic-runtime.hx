class ImplicitRuntimeFeature {
	public function new() {}
}

class ImplicitRuntimeOwner implements Observable {
	public var count:Int = 0;
	public function new() {}
	public function add<T:ImplicitRuntimeFeature>(value:T):T {
		count++;
		return value;
	}
}

class ImplicitRuntimeNoConstructor implements Observable {
	public var value:Int = 1;
}

function main():Int {
	var owner = new ImplicitRuntimeOwner();
	var value = owner.add(new ImplicitRuntimeFeature());
	var plain = new ImplicitRuntimeNoConstructor();
	return value != null && owner.count == 1 && plain.value == 1 ? 42 : 24;
}
