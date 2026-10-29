package haxeon.agent.nativekit;

import haxe.io.Bytes;
import haxeon.agent.Cancelable;
import haxeon.agent.HttpStreamSink;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetTypes.HttpError;
import nativekit.ffi.NativeKitNetTypes.HttpStreamHandle;
import nativekit.ffi.NativeKitTypes.Result;

/** One in-flight streaming request. Terminal state is reached exactly once. */
class NativeKitStreamRequest implements Cancelable {
	final transport:NativeKitHttpTransport;
	final sink:HttpStreamSink;
	var request:Null<haxe.Int64>;
	var stream:Null<HttpStreamHandle>;
	var finished = false;

	public function new(transport:NativeKitHttpTransport, sink:HttpStreamSink) {
		this.transport = transport;
		this.sink = sink;
	}

	public function begin(request:haxe.Int64, stream:HttpStreamHandle):Void {
		this.request = request;
		this.stream = stream;
	}

	public function headers(result:Result, status:Int):Void {
		if (finished)
			return;
		if (result != Result.Ok) {
			finishWith(describe(result));
			return;
		}
		sink.headers(status);
	}

	/** Moves every currently buffered byte to the sink. */
	public function drain(scratch:Bytes):Void {
		var open = stream;
		if (finished || open == null)
			return;
		while (!finished) {
			var read = NativeKitNet.nk_http_stream_read(open, scratch, scratch.length);
			var code:Int = read.status;
			if (code == HttpError.WouldBlock)
				return;
			if (read.status != Result.Ok) {
				finishWith(describe(read.status));
				return;
			}
			var count = haxe.Int64.toInt(read.out_read);
			if (count <= 0)
				return;
			sink.chunk(scratch.sub(0, count));
		}
	}

	public function complete(result:Result, scratch:Bytes):Void {
		if (finished)
			return;
		drain(scratch);
		if (finished)
			return;
		if (result != Result.Ok) {
			finishWith(describe(result));
			return;
		}
		release();
		sink.complete();
	}

	public function finishWith(message:String):Void {
		if (finished)
			return;
		release();
		sink.fail(message);
	}

	public function cancel():Void {
		if (finished)
			return;
		release();
		if (request != null)
			NativeKitNet.nk_http_cancel(request);
	}

	function release():Void {
		finished = true;
		transport.forget(this);
		var open = stream;
		stream = null;
		if (open != null)
			NativeKitNet.nk_http_stream_close(open);
	}

	static function describe(result:Result):String
		return "Network error (" + result + ")";
}
