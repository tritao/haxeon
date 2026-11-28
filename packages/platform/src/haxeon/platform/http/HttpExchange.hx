package haxeon.platform.http;

import haxe.io.Bytes;
import haxeon.async.Future;
import haxeon.async.Outcome;
import haxeon.async.Promise;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetTypes.HttpStreamHandle;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;

/**
 * One HTTP request in flight (`HttpClient.send`). `response` settles when the status and headers arrive, and
 * `complete` when the request ends: with the whole body, or, for a streaming request, after the last of it reached
 * `onData`. A failure settles both with its `NativeKitError`; a cancelled request settles them `Cancelled`.
 */
class HttpExchange {
	static inline var ReadChunk = 16384;

	/** The status and headers, once they arrive. */
	public final response:Future<Result<HttpResponse, NativeKitError>>;

	/** The finished response; for a streaming request, its body has gone to `onData` instead. */
	public final complete:Future<Result<HttpResponse, NativeKitError>>;

	final request:haxe.Int64;
	final responsePromise = new Promise<Result<HttpResponse, NativeKitError>>();
	final completePromise = new Promise<Result<HttpResponse, NativeKitError>>();
	final forget:HttpExchange->Void;
	var stream:Null<HttpStreamHandle>;
	var scratch:Null<Bytes> = null;
	var dataHandler:Null<Bytes->Void> = null;
	var progressHandler:Null<HttpProgress->Void> = null;
	var cancelRequested = false;

	@:allow(haxeon.platform.http.HttpClient)
	private function new(request:haxe.Int64, stream:Null<HttpStreamHandle>, forget:HttpExchange->Void) {
		this.request = request;
		this.stream = stream;
		this.forget = forget;
		response = responsePromise.future;
		complete = completePromise.future;
		responsePromise.setControls(requestCancel);
		completePromise.setControls(requestCancel);
	}

	/** Gives each piece of a streaming request's body to `handler` as it arrives, in order. */
	public function onData(handler:Bytes->Void):Void
		dataHandler = handler;

	/** Gives `handler` the request's progress as NativeKit reports it. */
	public function onProgress(handler:HttpProgress->Void):Void
		progressHandler = handler;

	/** Asks NativeKit to stop the request; its futures settle `Cancelled` once it has. False when it already ended. */
	public function cancel():Bool {
		if (complete.isComplete() || cancelRequested)
			return false;
		requestCancel();
		return true;
	}

	/** Whether the request has ended. */
	public function isComplete():Bool
		return complete.isComplete();

	internal function key():String
		return Std.string(request);

	internal function receive(signal:HttpSignal):Void {
		switch signal {
			case Headers(_, arrived):
				settle(responsePromise, arrived);
			case DataAvailable(_):
				switch drain() {
					// A body that cannot be read ends the request with why.
					case Err(error):
						requestCancel();
						end(Err(error));
					case Ok(_):
				}
			case Progress(_, progress):
				if (progressHandler != null)
					progressHandler(progress);
			case Complete(_, finished):
				// The last of a streaming body is read before the request ends; a read that fails ends it with why.
				var outcome:Result<HttpResponse, NativeKitError> = switch drain() {
					case Err(error): Err(error);
					case Ok(_): finished;
				};
				end(outcome);
		}
	}

	/** Ends the exchange as cancelled, when its client or runtime goes away first. */
	internal function abandon():Void {
		if (complete.isComplete())
			return;
		requestCancel();
		end(Err(Cancelled));
	}

	/** Reads what has arrived of a streaming body, giving it to `onData`; answers why a read failed. */
	function drain():Result<Void, NativeKitError> {
		var open = stream;
		if (open == null)
			return Ok();
		var buffer = scratch == null ? scratch = Bytes.alloc(ReadChunk) : scratch;
		while (true) {
			var read = NativeKitNet.nk_http_stream_read(open, buffer, buffer.length);
			if (read.status == NativeResult.HttpWouldBlock)
				return Ok();
			if (read.status != NativeResult.Ok)
				return Err(NativeKitStatus.reported(read.status, NativeKit.nk_last_error()));
			var count = haxe.Int64.toInt(read.out_read);
			if (count <= 0)
				return Ok();
			if (dataHandler != null)
				dataHandler(buffer.sub(0, count));
		}
	}

	function end(outcome:Result<HttpResponse, NativeKitError>):Void {
		var open = stream;
		stream = null;
		if (open != null)
			NativeKitNet.nk_http_stream_close(open);
		forget(this);
		// A request that failed before its headers arrived answers `response` with the same failure.
		settle(responsePromise, outcome);
		settle(completePromise, outcome);
	}

	function requestCancel():Void {
		if (cancelRequested)
			return;
		cancelRequested = true;
		NativeKitNet.nk_http_cancel(request);
	}

	static function settle(promise:Promise<Result<HttpResponse, NativeKitError>>,
			answer:Result<HttpResponse, NativeKitError>):Void {
		if (promise.future.isComplete())
			return;
		promise.resolve(switch answer {
			case Err(Cancelled): Outcome.Cancelled;
			case _: Success(answer);
		});
	}
}
