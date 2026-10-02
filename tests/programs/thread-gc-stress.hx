import sys.thread.Mutex;
import sys.thread.Thread;

class Link {
	public var next:Link;
	public var value:Int;
	public var label:String;

	public function new(value:Int) {
		this.value = value;
		this.label = "n" + value;
	}
}

/** Builds a chain that only this thread's locals keep alive, then churns garbage and re-checks it. */
function worker(seed:Int, rounds:Int):Int {
	var head:Link = null;
	var expected = 0;
	for (i in 0...5000) {
		var link = new Link(seed + i);
		link.next = head;
		head = link;
		expected += seed + i;
	}
	var scratch = new Array<Int>();
	for (round in 0...rounds) {
		// garbage of several shapes, so collections start while other threads are allocating too
		for (i in 0...4000) {
			var garbage = new Link(i);
			garbage.next = new Link(i + 1);
			scratch.push(garbage.value);
		}
		scratch = new Array<Int>();
		var sum = 0;
		var count = 0;
		var cursor = head;
		while (cursor != null) {
			if (cursor.label != "n" + cursor.value)
				return -1;
			sum += cursor.value;
			count++;
			cursor = cursor.next;
		}
		if (sum != expected || count != 5000)
			return -2;
	}
	return expected;
}

function main():Int {
	var threads = 4;
	var rounds = 25;
	var mutex = new Mutex();
	var results = [for (i in 0...threads) 0];
	var finished = [0];
	for (index in 0...threads) {
		Thread.create(function() {
			var result = worker((index + 1) * 100000, rounds);
			mutex.acquire();
			results[index] = result;
			finished[0] = finished[0] + 1;
			mutex.release();
		});
	}
	// the main thread allocates concurrently as well
	var mine = worker(7, rounds);
	var waited = 0;
	while (waited < 20000) {
		mutex.acquire();
		var done = finished[0];
		mutex.release();
		if (done == threads)
			break;
		Sys.sleep(0.001);
		waited++;
	}
	if (mine < 0)
		return 1;
	if (waited >= 20000)
		return 2;
	for (index in 0...threads) {
		var seed = (index + 1) * 100000;
		var expected = 0;
		for (i in 0...5000)
			expected += seed + i;
		if (results[index] != expected)
			return 3;
	}
	return 42;
}
