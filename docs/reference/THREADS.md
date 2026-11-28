# Threads

`std.thread` runs functions on threads of their own and shares state between them: `Thread`, `Mutex`, `Condition`,
`Semaphore` and `ThreadLocal`. It is not available on the Wasm targets, which run on one thread: importing it there is a
compile error.

```haxe
import std.thread.Thread;

function checksums(paths:Array<String>):Array<Int> {
	var workers = [for (path in paths) Thread.spawn("app.checksum", () -> checksum(path))];
	return [for (worker in workers) worker.join()];
}
```

## Threads

`Thread.spawn(name, run)` starts a thread running `run`. Every thread has a name, which debuggers, crash dumps and
profiler captures show ([Profiling](PROFILING.md)): say what it does, and put what tells threads apart first, since
Linux keeps a name's first 15 bytes. A thread a native library started names itself with `Thread.nameCurrent(name)`.

| Method | Does |
| --- | --- |
| `join()` | waits for the thread to finish, and answers what `run` returned |
| `wait(timeoutSeconds)` | waits up to the timeout (negative: without limit): whether the thread has finished |
| `isFinished()` | whether it has finished, without waiting |
| `name` | the name it was started with |

A `run` that throws is a bug, and is treated as one where it happens: the thread ends with the exception printed, as an
uncaught exception is, and `join` throws it again for the thread that needed the result. A thread nobody joins simply
ends; the program does not wait for it when its main function returns.

## Locks and conditions

A `Mutex` is held by one thread at a time; the thread holding it may take it again, and gives it back once for each
take. `tryAcquire()` takes it only if no other thread holds it. Give it back with `defer` so every path does:

```haxe
guard.acquire();
defer guard.release();
```

A `Condition` has a lock of its own. A thread holding it waits with `wait()` until another, holding it in turn, calls
`signal()` (one waiter) or `broadcast()` (all of them). `wait(timeoutSeconds)` gives up after the timeout, answering
whether it was woken. A wait can end without a signal, so wait in a loop on the state the lock guards:

```haxe
ready.acquire();
while (queue.length == 0)
	ready.wait();
var job = queue.shift();
ready.release();
```

## Semaphores

A `Semaphore` hands permits between threads: `release()` adds one and `acquire()` takes one, waiting until there is
one. A release before the acquire counts as much as one after it, so one thread can wait for another's work without a
race on who comes first. `tryAcquire(timeoutSeconds)` takes a permit only if one comes within the timeout (by default,
only one already there). `new Semaphore(permits)` starts with permits in hand, to bound how many threads do something
at once. Timeouts are measured on the monotonic clock, so a change to the system's time moves none of them.

## Thread-local values

A `ThreadLocal<T>` holds a value for each thread: `value` is the calling thread's, null until that thread sets one.

## Haxe's `sys.thread`

`sys.thread` is Haxe's API, kept for code ported from Haxe as adapters over `std.thread`: `Thread.create` starts a
thread named `sys.thread`, `Lock` is a `Semaphore`, `Tls` a `ThreadLocal`, and `Mutex` and `Condition` are the ones
here. On Wasm it keeps Haxe's single-threaded behaviour instead ([Wasm backend](WASM_BACKEND.md)): a created thread runs
to completion before `create` returns.
