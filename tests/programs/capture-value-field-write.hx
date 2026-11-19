// A captured value-type local that a closure writes through a field is one variable: the closure and the function see each
// other's writes, as for a whole-value write.
@:value
class Counter {
	public var n:Int;

	public function new(n:Int) {
		this.n = n;
	}
}

function main():Int {
	var counter = new Counter(1);
	var bump = () -> counter.n += 1;
	bump();
	bump();
	counter.n += 10;
	var read = () -> counter.n;
	var replaced = () -> counter = new Counter(100);
	var before = read();
	replaced();
	return before == 13 && read() == 100 && counter.n == 100 ? 42 : 1;
}
