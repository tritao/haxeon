class Counter {
	public var count:Int;
	public function new() count = 0;
	public function touch():Int {
		count += 1;
		return count;
	}
}

function choose(flag:Bool):Int {
	var value = 0;
	if (flag) value = 20; else value = 21;
	var unused = (value + 9) * 3;
	return value;
}

function main():Int {
	var counter = new Counter();
	var discardedCallResult = counter.touch();
	var sum = 0;
	for (i in 0...2) sum += choose(i == 0);
	return sum + counter.count;
}
