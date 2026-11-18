// A `Null<T>` is read as a `T`, as Haxe unifies them: a generic function and a generic class return what `Array.shift` and
// `Array.pop` give, and a missing value reads as `T`'s null.
class Queue<T> {
	final values:Array<T>;

	public function new(values:Array<T>)
		this.values = values;

	public function next():T
		return values.shift();
}

class Main {
	static function first<T>(values:Array<T>):T
		return values.shift();

	static function last<T>(values:Array<T>):T {
		var value:Null<T> = values.pop();
		return value;
	}

	static function main() {
		Sys.println(first([3, 4]));
		Sys.println(first(["a", "b"]));
		Sys.println(last([5, 6]));
		var queue = new Queue(["x", "y"]);
		Sys.println(queue.next());
		Sys.println(queue.next());
		Sys.println(queue.next());
		Sys.println(first(([]:Array<String>)));
	}
}
