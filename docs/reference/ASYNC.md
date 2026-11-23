# Futures and promises

A `haxeon.async.Future<T>` represents one eventual outcome. Consumers register
`onComplete` callbacks and the producer owns the corresponding `Promise<T>`.

| Outcome | Meaning |
| --- | --- |
| `Success(value)` | The producer completed with a value. |
| `Failure(error)` | The operation failed with a `haxe.Exception`. |
| `Cancelled` | The producer settled the operation as cancelled. |
| `Stopped` | Observation ended. The work may continue. |

The first terminal outcome wins. An observer added after completion runs
immediately. A producer can install a cancellation hook and an optional
detach hook with `Promise.setControls`. When `canCancel()` is true, `cancel()`
requests cancellation once and sets `isCancellationRequested()`. The
producer still owns settlement. `stopObserving()` settles the future as
`Stopped` and runs the detach hook to release tracking.

Futures create no threads and have no scheduler. Use a future on its owning
thread. Producers deliver asynchronous work from the owner's poll or tick,
such as `EventPump.poll`, `RpcConnection.poll`, or a UI frame. Work completed
elsewhere must post to the owner before settling the promise. For example,
NativeKit delivers completion events through `EventPump.poll`, where the
platform's `Requests` registry settles promises. Callbacks run on the owner
as part of settlement or immediate registration.
