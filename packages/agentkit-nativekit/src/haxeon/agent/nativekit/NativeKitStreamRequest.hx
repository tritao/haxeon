package haxeon.agent.nativekit;

import haxeon.agent.Cancelable;
import haxeon.agent.HttpStreamSink;
import haxeon.platform.http.HttpExchange;

/** One in-flight streaming request, reaching its sink's terminal state exactly once. */
internal class NativeKitStreamRequest implements Cancelable {
	final exchange:Null<HttpExchange>;
	final sink:HttpStreamSink;
	var finished:Bool;

	/** The request `exchange` streams to `sink`; with no exchange, one that has already failed. */
	public function new(exchange:Null<HttpExchange>, sink:HttpStreamSink) {
		this.exchange = exchange;
		this.sink = sink;
		finished = exchange == null;
		if (exchange == null)
			return;
		exchange.response.onComplete(function(outcome) switch outcome {
			case Success(Ok(response)): if (!finished) sink.headers(response.statusCode);
			case _:
		});
		exchange.onData(function(bytes) {
			if (!finished)
				sink.chunk(bytes);
		});
		exchange.complete.onComplete(function(outcome) {
			if (finished)
				return;
			finished = true;
			switch outcome {
				case Success(Ok(_)): sink.complete();
				case Success(Err(error)): sink.fail("Network error: " + error.describe());
				case Cancelled: sink.fail("The HTTP request was cancelled");
				case Stopped: sink.fail("The HTTP request was abandoned");
			}
		});
	}

	public function cancel():Void {
		if (finished)
			return;
		finished = true;
		if (exchange != null)
			exchange.cancel();
	}
}
