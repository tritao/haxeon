package profiler;

import haxe.Int64;
import haxe.Timer;
import haxe.io.Bytes;
import sys.io.File;
import sys.io.FileOutput;
import profiler.HldiCodec.HldiFrames;
import profiler.HldiTypes.HldiFrame;

/** Streaming writer for the native hlprof-live HLPC/2 capture format: the pushed frames, written as they arrive. */
class HlpcCapture {
	static inline final TYPE_COMPLETE = 3;

	final output:FileOutput;
	final started = Timer.stamp();
	var closed = false;
	var frames:Int64 = Int64.ofInt(0);
	var bytes:Int64 = Int64.ofInt(0);

	public function new(path:String, processId:Int, sampleRate:Int, sources:Int) {
		output = File.write(path, true);
		var header = Bytes.alloc(24);
		header.blit(0, Bytes.ofString("HLPC"), 0, 4);
		put16(header, 4, 2);
		put16(header, 6, 24);
		put32(header, 12, processId);
		put32(header, 16, sampleRate);
		put32(header, 20, sources);
		output.write(header);
	}

	/** Writes a frame the runtime pushed, with its type and payload unchanged. */
	public function frame(frame:HldiFrame):Void
		record(frame.type, frame.payload);

	/** Writes a metadata snapshot as a metadata frame (type 4). */
	public function metadata(payload:Bytes):Void
		record(HldiFrames.PUSH_METADATA, payload);

	/** Ends the capture; only a session that reached its end frame is complete. */
	public function close(complete:Bool = true):Void {
		if (closed)
			return;
		if (complete) {
			var payload = Bytes.alloc(16);
			put64(payload, 0, frames);
			put64(payload, 8, bytes);
			writeRecord(TYPE_COMPLETE, payload);
		}
		closed = true;
		output.close();
	}

	function record(type:Int, payload:Bytes):Void {
		if (closed)
			return;
		writeRecord(type, payload);
		frames = Int64.add(frames, Int64.ofInt(1));
		bytes = Int64.add(bytes, Int64.ofInt(payload.length));
	}

	function writeRecord(type:Int, payload:Bytes):Void {
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
