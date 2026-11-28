import haxeon.Hashing;

struct Key implements Hashable {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

class LateBox<T:Hashable> {
	var value:T;
	public function new(value:T) this.value = value;
	public function hash():Int return Hashing.hash(value);
}

enum Late<T> {
	Data(value:T);
}

// Typing this method happens after ordinary source bodies. Its generic owner,
// hash helper, key path and captured closure must still participate in completion.
enum Value implements Equatable {
	Item(value:Int);
	public function equals(other:Value):Bool {
		var late:Late<Key> = Data(new Key(42));
		return switch late {
			case Data(key):
				var box = new LateBox(key);
				var path = \Key.value;
				var read = () -> box.hash() + path.get(key);
				read() == Hashing.hash(key) + key.value;
		};
	}
}

function main():Int return Item(1) == Item(2) ? 42 : 1;
