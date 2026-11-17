// Unannotated arguments of a generic class's constructor and methods, and of a static generic function, typed from their bodies
// in the declaration's own type parameters, used from another generic class and from a concrete one.
class Node<T> {
	public var data:T;
	public var next:Null<Node<T>>;

	public inline function new(data) {
		this.data = data;
		next = null;
	}

	public function replace(value) {
		var old = data;
		data = value;
		return old;
	}

	public function link(other) {
		next = other;
		return this;
	}

	public function following() {
		var after = next;
		return after == null ? data : after.data;
	}

	public static function pair<U>(first:U, second) {
		var node = new Node(first);
		node.link(new Node(second));
		return node;
	}
}

class Box<K, V> {
	public var key:K;
	public var value:V;

	public function new(key, value) {
		this.key = key;
		this.value = value;
	}

	public function swap(next) {
		var old = value;
		value = next;
		return old;
	}
}

class Holder<T> {
	public function new() {}

	public function wrap(data:T):Node<T> {
		var node = new Node(data);
		return node;
	}

	public function chain(first:T, second:T):Node<T> {
		var head = new Node(first);
		head.link(new Node(second));
		head.replace(second);
		return head;
	}

	public function boxed(name:String, data:T):Box<String, T> {
		return new Box(name, data);
	}
}

class Concrete {
	public static function run():Void {
		var node = new Node("a");
		Sys.println(node.replace("b") + node.data);
		var linked = new Node(1).link(new Node(2));
		Sys.println(linked.data + linked.following());
		var paired = Node.pair(1.5, 2.5);
		Sys.println(paired.data + paired.following());
		var box = new Box(3, "three");
		Sys.println(box.swap("drei") + " " + box.value + " " + box.key);
	}
}

class Main {
	static function main() {
		var holder = new Holder<Int>();
		Sys.println(holder.wrap(42).data);
		var chain = holder.chain(1, 2);
		Sys.println(chain.data + chain.following());
		var strings = new Holder<String>();
		var box = strings.boxed("k", "v");
		Sys.println(box.key + box.swap("w") + box.value);
		Concrete.run();
	}
}
