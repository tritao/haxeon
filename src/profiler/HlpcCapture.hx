package profiler;

import haxe.Int64;
import haxe.Timer;
import haxe.io.Bytes;
import sys.io.File;
import sys.io.FileOutput;

/** Streaming writer for the native hlprof-live HLPC/1 capture format. */
class HlpcCapture {
	final output:FileOutput;
	final started = Timer.stamp();
	var closed = false;

	public function new(path:String, processId:Int, sampleRate:Int) {
		output = File.write(path, true);
		var header = Bytes.alloc(24);
		header.blit(0, Bytes.ofString("HLPC"), 0, 4);
		put16(header, 4, 1);
		put16(header, 6, 24);
		put32(header, 12, processId);
		put32(header, 16, sampleRate);
		output.write(header);
	}

	public function metadata(bytes:Bytes):Void
		record(1, bytes);

	public function samples(requested:Int64, next:Int64, dropped:Int64, bytes:Bytes):Void {
		var payload = Bytes.alloc(24 + bytes.length);
		put64(payload, 0, requested);
		put64(payload, 8, next);
		put64(payload, 16, dropped);
		payload.blit(24, bytes, 0, bytes.length);
		record(2, payload);
	}

	public function close(cursor:Int64, dropped:Int64):Void {
		if (closed)
			return;
		var payload = Bytes.alloc(16);
		put64(payload, 0, cursor);
		put64(payload, 8, dropped);
		record(3, payload);
		closed = true;
		output.close();
	}

	function record(type:Int, payload:Bytes):Void {
		var header = Bytes.alloc(16);
		put32(header, 0, type);
		put32(header, 4, payload.length);
		put64(header, 8, Int64.fromFloat((Timer.stamp() - started) * 1000000000.0));
		output.write(header);
		output.write(payload);
		output.flush();
	}

	static function put16(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, value);
		bytes.set(at + 1, value >>> 8);
	}

	static function put32(bytes:Bytes, at:Int, value:Int):Void {
		for (index in 0...4)
			bytes.set(at + index, value >>> (index * 8));
	}

	static function put64(bytes:Bytes, at:Int, value:Int64):Void {
		put32(bytes, at, value.low);
		put32(bytes, at + 4, value.high);
	}
}
