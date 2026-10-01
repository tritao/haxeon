// A generic abstract's method called without a receiver runs on `this`, with its type arguments.
abstract Box<T>(Array<T>) {
	public inline function new(values:Array<T>)
		this = values;

	public inline function all(index:Int):Array<T>
		return (cast this : Array<T>);

	public inline function first(index:Int):T {
		var values = all(index);
		return values[index];
	}

	public function both():Array<T>
		return [first(0), first(0)];
}

function main():Int {
	var numbers = new Box<Float>([1.5]), names = new Box<String>(["x"]);
	if (numbers.first(0) != 1.5 || names.first(0) != "x" || numbers.both().length != 2 || numbers.both()[1] != 1.5)
		return 1;
	return 42;
}
