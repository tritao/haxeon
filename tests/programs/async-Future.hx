import haxeon.async.Promise;

function main():Int {
	var promise = new Promise<Int>();
	var future = promise.future;
	var sum = 0;
	future.onComplete(outcome -> switch outcome {
		case Success(value): sum += value;
		case _:
	});
	promise.complete(7);
	promise.complete(40);
	future.onComplete(outcome -> switch outcome {
		case Success(value): sum += value;
		case _:
	});
	if (sum != 14 || !future.isComplete() || future.canCancel() || future.stopObserving())
		return 1;

	var cancelled = new Promise<Int>();
	var requests = 0;
	var sawCancelled = false;
	cancelled.setControls(() -> requests++);
	cancelled.future.onComplete(outcome -> sawCancelled = outcome.match(Cancelled));
	if (!cancelled.future.canCancel() || !cancelled.future.cancel() || cancelled.future.cancel()
		|| !cancelled.future.isCancellationRequested() || cancelled.future.isComplete() || requests != 1)
		return 2;
	cancelled.cancel();
	if (!sawCancelled)
		return 3;

	var detached = new Promise<Int>();
	var detaches = 0;
	var sawStopped = false;
	detached.setControls(() -> requests++, () -> {
		detaches++;
		detached.complete(99);
	});
	detached.future.onComplete(outcome -> sawStopped = outcome.match(Stopped) && detaches == 1);
	if (!detached.future.stopObserving() || detached.future.stopObserving() || !sawStopped || requests != 1
		|| detached.future.cancel())
		return 4;

	var failed = new Promise<Int>();
	var exception = new haxe.Exception("failure");
	var sameException = false;
	failed.fail(exception);
	failed.future.onComplete(outcome -> switch outcome {
		case Failure(error): sameException = error == exception;
		case _:
	});
	if (!sameException)
		return 5;

	// A promise of no value completes with none, and its success carries none.
	var done = new Promise<Void>();
	var completions = 0;
	done.future.onComplete(outcome -> switch outcome {
		case Success(): completions++;
		case _:
	});
	done.complete();
	return completions == 1 ? 42 : 6;
}
