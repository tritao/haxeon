enum ListenerEvent {
	Value(value:Int);
	Empty;
}

class ListenerOwner {
	var listeners:Array<ListenerEvent->Void>;
	public function new() {}
	public function answer():Int return 42;
}

function main():Int {
	var owner = new ListenerOwner();
	var event = ListenerEvent.Value(42);
	return switch event {
		case Value(value): owner.answer() == value ? value : 0;
		case Empty: 0;
	};
}
