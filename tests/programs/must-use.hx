// A Result is must-use: it is handled, or dropped on purpose with `_ = value;`, as a statement or as the body of a lambda
// that returns Void. The dropped value is still computed.
enum SaveError {
	Full;
}

class Store {
	public var saved = 0;

	public function new() {}

	public function save(size:Int):Result<Int, SaveError> {
		saved++;
		return size > 8 ? Err(Full) : Ok(size);
	}
}

function each(values:Array<Int>, f:Int->Void):Void
	for (value in values)
		f(value);

function main():Int {
	var store = new Store();
	_ = store.save(1);
	each([2, 3], size -> _ = store.save(size));
	each([4], size -> {
		_ = store.save(size);
	});
	for (size in [5, 6])
		_ = store.save(size);
	if (store.saved != 6)
		return 1;
	var kept = store.save(9);
	switch kept {
		case Ok(_):
			return 2;
		case Err(Full):
	}
	return store.save(7).unwrapOr(0) == 7 ? 42 : 3;
}
