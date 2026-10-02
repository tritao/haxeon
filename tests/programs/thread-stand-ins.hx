import sys.thread.Condition;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

function main():Int {
	var result = 0;
	var done = new Lock();
	// The thread's work is finished by the time the lock is waited on, whether it ran beside the caller or before it.
	Thread.create(() -> {
		result = 40;
		done.release();
	});
	if (!done.wait(5.0))
		return 1;
	// Nothing was released again, so a timed wait gives up.
	if (done.wait(0.01))
		return 2;
	var mutex = new Mutex();
	mutex.acquire();
	if (!mutex.tryAcquire())
		return 3;
	mutex.release();
	mutex.release();
	var condition = new Condition();
	condition.acquire();
	condition.signal();
	condition.broadcast();
	if (condition.timedWait(0.01))
		return 4;
	condition.release();
	// Releases count: each one lets one wait through.
	done.release();
	done.release();
	if (!done.wait() || !done.wait())
		return 5;
	return result + 2;
}
