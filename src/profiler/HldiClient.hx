package profiler;

import haxe.Int64;
import haxe.io.Bytes;
import profiler.HldiCodec.HldiReader;
import profiler.HldiTypes.HldiHello;
import profiler.HldiTypes.HldiMetadata;
import profiler.HldiTypes.HldiReadResult;
import profiler.HldiTypes.HldiStatus;
import sys.net.Host;
import sys.net.Socket;

/** Synchronous, dependency-free client for the HashLink Diagnostics Interface. */
class HldiClient {
	public static inline final CAP_PROFILER = 1;
	public static inline final CAP_SYMBOLS = 2;

	static inline final SERVICE_PROFILER = 2;
	static inline final PROFILE_STATUS = 1;
	static inline final PROFILE_CONFIGURE = 2;
	static inline final PROFILE_READ = 3;
	static inline final PROFILE_METADATA = 4;
	static inline final FLAG_RESPONSE = 1;
	static inline final FLAG_ERROR = 2;
	static inline final MAX_REPLY = 64 * 1024 * 1024;

	public final hello:HldiHello;
	var socket:Socket;
	var nextRequestId = 1;
	var closed = false;

	public function new(host:String, port:Int, timeoutSeconds:Float = 5.0) {
		if (port <= 0 || port > 65535)
			throw 'Invalid HLDI port $port';
		socket = new Socket();
		socket.setTimeout(timeoutSeconds);
		socket.connect(new Host(host), port);
		var bytes = readExact(16);
		if (bytes.getString(0, 4) != "HLDI") {
			close();
			throw "Endpoint did not send an HLDI greeting";
		}
		var input = new HldiReader(bytes), magic = input.take(4), version = input.u16(), capabilities = input.u16();
		if (version != 1) {
			close();
			throw 'Unsupported HLDI version $version';
		}
		hello = new HldiHello(version, capabilities, input.u32(), input.u32());
	}

	public function status():HldiStatus
		return decodeStatus(request(PROFILE_STATUS, Bytes.alloc(0)));

	public function configure(sampleRate:Int, enabled:Bool):HldiStatus {
		if (sampleRate <= 0)
			throw 'Invalid profiler sample rate $sampleRate';
		var payload = Bytes.alloc(8);
		put32(payload, 0, sampleRate);
		put32(payload, 4, enabled ? 1 : 0);
		return decodeStatus(request(PROFILE_CONFIGURE, payload));
	}

	public function read(cursor:Int64, maxBytes:Int = 256 * 1024):HldiReadResult {
		if (maxBytes <= 0)
			throw 'Invalid HLDI read size $maxBytes';
		if (maxBytes > 256 * 1024)
			maxBytes = 256 * 1024;
		var payload = Bytes.alloc(12);
		put64(payload, 0, cursor);
		put32(payload, 8, maxBytes);
		var input = new HldiReader(request(PROFILE_READ, payload));
		var next = input.u64(), dropped = input.u64(), bytes = input.take(input.remaining());
		return new HldiReadResult(next, dropped, bytes);
	}

	public function metadata():HldiMetadata
		return HldiCodec.metadata(request(PROFILE_METADATA, Bytes.alloc(0)));

	public function close():Void {
		if (closed)
			return;
		closed = true;
		try socket.close() catch (_:Dynamic) {}
	}

	function request(type:Int, payload:Bytes):Bytes {
		if (closed)
			throw "HLDI client is closed";
		var id = nextRequestId++, header = Bytes.alloc(16);
		header.set(0, SERVICE_PROFILER);
		header.set(1, type);
		put32(header, 4, id);
		put32(header, 8, payload.length);
		socket.output.writeFullBytes(header, 0, header.length);
		if (payload.length != 0)
			socket.output.writeFullBytes(payload, 0, payload.length);
		socket.output.flush();

		var reply = new HldiReader(readExact(16)), service = reply.u8(), replyType = reply.u8(), flags = reply.u16(), replyId = reply.u32(), length = reply.u32();
		reply.u32();
		if (service != SERVICE_PROFILER || replyType != type || replyId != id || flags & FLAG_RESPONSE == 0)
			throw 'Mismatched HLDI response for request $id';
		if (length < 0 || length > MAX_REPLY)
			throw 'Invalid HLDI response length $length';
		var body = readExact(length);
		if (flags & FLAG_ERROR != 0)
			throw 'HLDI request $id failed';
		return body;
	}

	function readExact(length:Int):Bytes {
		var result = Bytes.alloc(length), position = 0;
		while (position < length) {
			var count = socket.input.readBytes(result, position, length - position);
			if (count <= 0)
				throw "HLDI connection closed";
			position += count;
		}
		return result;
	}

	static function decodeStatus(bytes:Bytes):HldiStatus {
		if (bytes.length != 32)
			throw 'Invalid HLDI status length ${bytes.length}';
		var input = new HldiReader(bytes);
		return new HldiStatus(input.u64(), input.u64(), input.u64(), input.u32(), input.u32() != 0);
	}

	static function put32(bytes:Bytes, position:Int, value:Int):Void {
		bytes.set(position, value);
		bytes.set(position + 1, value >>> 8);
		bytes.set(position + 2, value >>> 16);
		bytes.set(position + 3, value >>> 24);
	}

	static function put64(bytes:Bytes, position:Int, value:Int64):Void {
		put32(bytes, position, value.low);
		put32(bytes, position + 4, value.high);
	}
}
