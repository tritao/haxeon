import sys.thread.Lock;
import sys.thread.Thread;

// A counting lock passes each release to one waiter, before or after it waits, and times out without one.
function main():Int {
	var early = new Lock();
	early.release();
	if (!early.wait(0.0))
		return 1;
	if (early.wait(0.01))
		return 2;
	var done = new Lock();
	for (_ in 0...4)
		Thread.create(function() done.release());
	for (_ in 0...4)
		if (!done.wait(5.0))
			return 3;
	return 42;
}
