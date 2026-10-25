package profiler;

import haxe.io.Bytes;
import profiler.HldiCodec.HldiReader;
import profiler.HldiTypes.HldiFrame;
import profiler.HldiTypes.HldiHello;
import profiler.HldiTypes.HldiMetadata;
import profiler.HldiTypes.HldiStatus;
import sys.net.Host;
import sys.net.Socket;

/**
	Synchronous, dependency-free client for the HashLink Diagnostics Interface (HLDI v2).

	While a session runs the runtime pushes frames between the responses to requests. A request that waits for its
	response queues the pushed frames it reads on the way; `nextFrame` hands them out in order.
**/
class HldiClient {
	public static inline final CAP_PROFILER = 1;
	public static inline final CAP_SYMBOLS = 2;
	public static inline final CAP_AUTH_REQUIRED = 4;

	public static inline final SOURCE_INSTRUMENT = 1;
	public static inline final SOURCE_SAMPLING = 2;
	public static inline final SOURCE_ALLOC = 4;

	static inline final SERVICE_CONTROL = 0;
	static inline final SERVICE_PROFILER = 2;
	static inline final CONTROL_AUTHENTICATE = 2;
	static inline final PROFILE_STATUS = 1;
	static inline final PROFILE_METADATA = 4;
	static inline final PROFILE_START = 16;
	static inline final PROFILE_STOP = 17;
	static inline final FLAG_RESPONSE = 1;
	static inline final FLAG_ERROR = 2;
	static inline final FLAG_PUSH = 4;
	static inline final MAX_REPLY = 64 * 1024 * 1024;

	public final hello:HldiHello;

	var socket:Socket;
	var nextRequestId = 1;
	var closed = false;
	final pushed:Array<HldiFrame> = [];

	public function new(host:String, port:Int, timeoutSeconds:Float = 5.0, ?token:String) {
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
		var input = new HldiReader(bytes),
			magic = input.take(4),
			version = input.u16(),
			capabilities = input.u16();
		if (version != 2) {
			close();
			throw 'Unsupported HLDI version $version';
		}
		hello = new HldiHello(version, capabilities, input.u32(), input.u32());
		if (capabilities & CAP_AUTH_REQUIRED != 0) {
			if (token == null || token.length == 0) {
				close();
				throw "HLDI endpoint requires authentication";
			}
			try
				requestService(SERVICE_CONTROL, CONTROL_AUTHENTICATE, Bytes.ofString(token))
			catch (error:Dynamic) {
				close();
				throw "HLDI authentication failed";
			}
		}
	}

	public function status():HldiStatus
		return decodeStatus(request(PROFILE_STATUS, Bytes.alloc(0)));

	/** Starts a session. The runtime then pushes frames, beginning with the session and metadata frames. */
	public function start(sources:Int, sampleRate:Int, allocationInterval:Int = 0, poolMiB:Int = 0):HldiStatus {
		if (sources <= 0 || sources > 7)
			throw 'Invalid profiler sources $sources';
		if (sampleRate <= 0)
			throw 'Invalid profiler sample rate $sampleRate';
		if (allocationInterval < 0)
			throw 'Invalid allocation sampling interval $allocationInterval';
		if (poolMiB < 0)
			throw 'Invalid profiler pool size $poolMiB';
		var payload = Bytes.alloc(16);
		put32(payload, 0, sources);
		put32(payload, 4, sampleRate);
		put32(payload, 8, allocationInterval);
		put32(payload, 12, poolMiB);
		return decodeStatus(request(PROFILE_START, payload));
	}

	/** Ends the session. Every remaining frame, ending with the end frame, is queued before this returns. */
	public function stop():HldiStatus
		return decodeStatus(request(PROFILE_STOP, Bytes.alloc(0)));

	/** The next pushed frame, waiting up to `timeoutSeconds` for one to arrive; null if none did. */
	public function nextFrame(timeoutSeconds:Float = 0.0):Null<HldiFrame> {
		if (pushed.length != 0)
			return pushed.shift();
		if (closed)
			throw "HLDI client is closed";
		if (Socket.select([socket], [], [], timeoutSeconds).read.length == 0)
			return null;
		var frame = readFrame();
		if (frame.flags & FLAG_PUSH == 0)
			throw "Unexpected HLDI response";
		return new HldiFrame(frame.type, frame.flags, frame.payload);
	}

	public function queuedFrames():Int
		return pushed.length;

	public function metadata():HldiMetadata
		return HldiCodec.metadata(metadataBytes());

	public function metadataBytes():Bytes
		return request(PROFILE_METADATA, Bytes.alloc(0));

	public function close():Void {
		if (closed)
			return;
		closed = true;
		try
			socket.close()
		catch (_:Dynamic) {}
	}

	function request(type:Int, payload:Bytes):Bytes {
		return requestService(SERVICE_PROFILER, type, payload);
	}

	function requestService(service:Int, type:Int, payload:Bytes):Bytes {
		if (closed)
			throw "HLDI client is closed";
		var id = nextRequestId++, header = Bytes.alloc(16);
		header.set(0, service);
		header.set(1, type);
		put32(header, 4, id);
		put32(header, 8, payload.length);
		socket.output.writeFullBytes(header, 0, header.length);
		if (payload.length != 0)
			socket.output.writeFullBytes(payload, 0, payload.length);
		socket.output.flush();

		while (true) {
			var frame = readFrame();
			if (frame.flags & FLAG_PUSH != 0) {
				pushed.push(new HldiFrame(frame.type, frame.flags, frame.payload));
				continue;
			}
			if (frame.service != service || frame.type != type || frame.requestId != id || frame.flags & FLAG_RESPONSE == 0)
				throw 'Mismatched HLDI response for request $id';
			if (frame.flags & FLAG_ERROR != 0)
				throw 'HLDI request $id failed';
			return frame.payload;
		}
	}

	function readFrame():{
		service:Int,
		type:Int,
		flags:Int,
		requestId:Int,
		payload:Bytes
	} {
		var reply = new HldiReader(readExact(16)),
			service = reply.u8(),
			type = reply.u8(),
			flags = reply.u16(),
			requestId = reply.u32(),
			length = reply.u32();
		reply.u32();
		if (length < 0 || length > MAX_REPLY)
			throw 'Invalid HLDI frame length $length';
		return {
			service: service,
			type: type,
			flags: flags,
			requestId: requestId,
			payload: readExact(length)
		};
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
		var active = input.u32() != 0,
			sources = input.u32(),
			chunks = input.u32(),
			chunksInUse = input.u32();
		return new HldiStatus(active, sources, chunks, chunksInUse, input.u64(), input.u64());
	}

	static function put32(bytes:Bytes, position:Int, value:Int):Void {
		bytes.set(position, value);
		bytes.set(position + 1, value >>> 8);
		bytes.set(position + 2, value >>> 16);
		bytes.set(position + 3, value >>> 24);
	}
}
