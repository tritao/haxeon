import sys.thread.Lock;
import sys.thread.Thread;
import sys.thread.Tls;

class Counter {
	public var count:Int = 0;

	public function new() {}
}

// Thread-local values: each thread sees only its own, starting unset, and keeps it across calls.
function main():Int {
	var local = new Tls<Counter>();
	if (local.value != null)
		return 1;
	var mine = new Counter();
	local.value = mine;
	var totals = [0, 0, 0, 0],
		unset = [true, true, true, true],
		done = new Lock();
	for (t in 0...4)
		Thread.create(function() {
			unset[t] = local.value == null;
			local.value = new Counter();
			for (_ in 0...10000)
				local.value.count++;
			totals[t] = local.value.count;
			done.release();
		});
	for (_ in 0...4)
		done.wait();
	for (t in 0...4)
		if (!unset[t] || totals[t] != 10000)
			return 2;
	return local.value == mine && mine.count == 0 ? 42 : 3;
}
