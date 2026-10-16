class State {
	public var failure:Null<String>;
	public var count:Null<Float>;

	public static var shared:Null<String>;
	public static var number:Null<Float>;

	public function new() {}

	public function change():Void
		failure = "changed";
}

typedef Record = {var failure:Null<String>;};

function instanceRead(state:State):Int {
	if (state.failure != null)
		throw "expected no failure";
	var copy:Null<String> = state.failure;
	if (copy != null || state.failure != null)
		return 0;
	if (state.count != null)
		return 0;
	var count:Null<Float> = state.count;
	return count == null ? 10 : 0;
}

function staticRead():Int {
	if (State.shared != null)
		throw "expected no shared failure";
	var copy:Null<String> = State.shared;
	if (copy != null || State.shared != null)
		return 0;
	if (State.number != null)
		return 0;
	var number:Null<Float> = State.number;
	return number == null ? 10 : 0;
}

function recordRead(record:Record):Int {
	if (record.failure != null)
		throw "expected no record failure";
	var copy:Null<String> = record.failure;
	return copy == null && record.failure == null ? 10 : 0;
}

function invalidatedRead(state:State):Int {
	if (state.failure != null)
		return 0;
	state.change();
	return state.failure == null ? 0 : 12;
}

function main():Int {
	var state = new State();
	return instanceRead(state) + staticRead() + recordRead({failure: null}) + invalidatedRead(state);
}
