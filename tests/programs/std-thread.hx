import std.thread.Condition;
import std.thread.Mutex;
import std.thread.Semaphore;
import std.thread.Thread;
import std.thread.ThreadLocal;

// std.thread: named threads that are joined for their result, rethrowing what they threw, and the locks, conditions,
// semaphores and thread-local values they share.

function fail():Int
	throw "expected failure";

function threads():Int {
	if (Thread.spawn("test.answer", () -> 6 * 7).join() != 42)
		return 1;
	var ran = false;
	var quiet = Thread.spawn("test.void", () -> {
		ran = true;
	});
	quiet.join();
	if (!ran || !quiet.isFinished() || quiet.name != "test.void")
		return 2;
	// A thread that throws ends with the exception printed; join throws it again.
	var failing = Thread.spawn("test.throws", fail);
	var rethrown:Dynamic = null;
	try {
		failing.join();
	} catch (error:Dynamic) {
		rethrown = error;
	}
	if (rethrown != "expected failure")
		return 3;
	// wait gives up after its timeout while the thread runs, and answers true once it has finished.
	var gate = new Semaphore();
	var held = Thread.spawn("test.held", () -> gate.acquire());
	if (held.wait(0.05) || held.isFinished())
		return 4;
	gate.release();
	if (!held.wait(5))
		return 5;
	return 0;
}

function locks():Int {
	var mutex = new Mutex();
	mutex.acquire();
	if (!mutex.tryAcquire())
		return 10; // Recursive: the holder takes it again.
	var fromOther = Thread.spawn("test.mutex", () -> mutex.tryAcquire()).join();
	mutex.release();
	mutex.release();
	if (fromOther)
		return 11;
	if (!Thread.spawn("test.mutex.free", () -> {
		var taken = mutex.tryAcquire();
		if (taken)
			mutex.release();
		return taken;
	}).join())
		return 12;

	var semaphore = new Semaphore(1);
	if (!semaphore.tryAcquire() || semaphore.tryAcquire() || semaphore.tryAcquire(0.02))
		return 13;
	semaphore.release();
	semaphore.acquire();
	var workers = [for (index in 0...4) Thread.spawn("test.release." + index, () -> semaphore.release())];
	for (_ in 0...4)
		if (!semaphore.tryAcquire(5))
			return 14;
	for (worker in workers)
		worker.join();

	var condition = new Condition(), ready = false;
	condition.acquire();
	if (condition.wait(0.02))
		return 15; // Nothing signals: the wait times out.
	var signaller = Thread.spawn("test.signal", () -> {
		condition.acquire();
		ready = true;
		condition.signal();
		condition.release();
	});
	while (!ready)
		if (!condition.wait(5))
			return 16;
	condition.release();
	signaller.join();
	return 0;
}

function locals():Int {
	var local = new ThreadLocal<String>();
	local.value = "main";
	var seen = Thread.spawn("test.local", () -> {
		var before = local.value;
		local.value = "worker";
		return before == null && local.value == "worker";
	}).join();
	if (!seen || local.value != "main")
		return 20;
	return 0;
}

function main():Int {
	for (part in [threads, locks, locals]) {
		var failure = part();
		if (failure != 0)
			return failure;
	}
	return 42;
}
