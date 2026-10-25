package profiler;

import haxe.Int64;
import haxe.Timer;
import haxe.io.Bytes;
import profiler.HldiCodec.HldiClock;
import profiler.HldiCodec.HldiFrames;
import profiler.HldiCodec.HldiReader;
import profiler.HldiTypes.HldiFrame;
import profiler.HldiTypes.HldiMetadata;
import profiler.HldiTypes.HldiRecord;
import profiler.HldiTypes.HldiSourceLine;
import profiler.HldiTypes.HldiSymbol;

enum abstract ProfilerSessionState(String) from String to String {
	var Connected = "connected";
	var Running = "running";
	var Paused = "paused";
	var Failed = "failed";
	var Closed = "closed";
}

class ProfileAggregate {
	public final key:String;
	public final stableKey:String;
	public final name:String;
	public final file:Null<String>;
	public final line:Null<Int>;
	public var selfSamples = 0;
	public var totalSamples = 0;
	/** Instrumented calls (functions only; lines have none). */
	public var calls = 0;

	public function new(key:String, stableKey:String, name:String, ?file:String, ?line:Int) {
		this.key = key;
		this.stableKey = stableKey;
		this.name = name;
		this.file = file;
		this.line = line;
	}
}

class ProfileStack {
	public final key:String;
	public final frames:Array<String>;
	public final frameDetails:Array<ProfileStackFrame>;
	public var samples = 0;
	public final threadSamples = new Map<Int, Int>();

	public function new(key:String, frameDetails:Array<ProfileStackFrame>) {
		this.key = key;
		this.frameDetails = frameDetails;
		frames = [for (frame in frameDetails) frame.name];
	}
}

class ProfileStackFrame {
	public final key:String;
	public final stableKey:String;
	public final name:String;
	public final revision:Int;
	public final file:Null<String>;
	public final line:Null<Int>;
	public final nativeModule:Null<String>;
	public final nativeOffset:Null<String>;

	public function new(key:String, stableKey:String, name:String, revision:Int, ?file:String, ?line:Int, ?nativeModule:String, ?nativeOffset:String) {
		this.key = key;
		this.stableKey = stableKey;
		this.name = name;
		this.revision = revision;
		this.file = file;
		this.line = line;
		this.nativeModule = nativeModule;
		this.nativeOffset = nativeOffset;
	}
}

class ProfileEvent {
	public final timestamp:Float;
	public final threadId:Int;
	public final eventId:Int;
	public final payload:Bytes;

	public function new(timestamp:Float, threadId:Int, eventId:Int, payload:Bytes) {
		this.timestamp = timestamp;
		this.threadId = threadId;
		this.eventId = eventId;
		this.payload = payload;
	}
}

class ProfileMetadataChange {
	public final timestamp:Float;
	public final moduleId:String;
	public final oldRevision:Int;
	public final newRevision:Int;

	public function new(timestamp:Float, moduleId:String, oldRevision:Int, newRevision:Int) {
		this.timestamp = timestamp;
		this.moduleId = moduleId;
		this.oldRevision = oldRevision;
		this.newRevision = newRevision;
	}
}

class ProfileGcStats {
	public final timestamp:Float;
	public final allocated:String;
	public final allocations:String;
	public final heap:String;
	public final collections:String;
	public final markMicros:String;

	public function new(timestamp:Float, allocated:Int64, allocations:Int64, heap:Int64, collections:Int64, markMicros:Int64) {
		this.timestamp = timestamp;
		this.allocated = Int64.toStr(allocated);
		this.allocations = Int64.toStr(allocations);
		this.heap = Int64.toStr(heap);
		this.collections = Int64.toStr(collections);
		this.markMicros = Int64.toStr(markMicros);
	}
}

class ProfileLeaf {
	public final timestamp:Float;
	public final threadId:Int;
	public final address:Int64;
	public final offset:Null<Int>;
	public final functionName:Null<String>;
	public final opcodeIndex:Null<Int>;
	public final opcode:Null<Int>;
	public final file:Null<String>;
	public final line:Null<Int>;

	public function new(timestamp:Float, threadId:Int, address:Int64, ?offset:Int, ?functionName:String, ?opcodeIndex:Int, ?opcode:Int, ?file:String,
			?line:Int) {
		this.timestamp = timestamp;
		this.threadId = threadId;
		this.address = address;
		this.offset = offset;
		this.functionName = functionName;
		this.opcodeIndex = opcodeIndex;
		this.opcode = opcode;
		this.file = file;
		this.line = line;
	}
}

class ProfileTimelineSample {
	public final sequence:Int;
	public final timestamp:Float;
	public final threadId:Int;
	public final stackKey:String;

	public function new(sequence:Int, timestamp:Float, threadId:Int, stackKey:String) {
		this.sequence = sequence;
		this.timestamp = timestamp;
		this.threadId = threadId;
		this.stackKey = stackKey;
	}
}

class ProfileAllocationSample {
	public final sequence:Int;
	public final timestamp:Float;
	public final threadId:Int;
	public final requested:String;
	public final allocated:String;
	public final interval:Int;
	public final typeKind:Int;
	public final frameDetails:Array<ProfileStackFrame>;

	public function new(sequence:Int, timestamp:Float, threadId:Int, requested:Int64, allocated:Int64, interval:Int, typeKind:Int,
			frameDetails:Array<ProfileStackFrame>) {
		this.sequence = sequence;
		this.timestamp = timestamp;
		this.threadId = threadId;
		this.requested = Int64.toStr(requested);
		this.allocated = Int64.toStr(allocated);
		this.interval = interval;
		this.typeKind = typeKind;
		this.frameDetails = frameDetails;
	}
}

class ProfilerSnapshot {
	public final state:ProfilerSessionState;
	public final samples:Int;
	public final instrumentedCalls:Int;
	public final unresolvedFrames:Int;
	public final functions:Array<ProfileAggregate>;
	public final lines:Array<ProfileAggregate>;
	public final stacks:Array<ProfileStack>;
	public final events:Array<ProfileEvent>;
	public final leaves:Array<ProfileLeaf>;
	public final metadataChanges:Array<ProfileMetadataChange>;
	public final metadataSchema:Int;
	public final metadataRevisions:Map<String, Int>;
	public final bufferCapacity:Int64;
	public final bufferUsed:Int64;
	public final bufferUtilization:Float;
	public final requestedSampleRate:Int;
	public final metadataRefreshMs:Float;
	public final sampleRecords:Int64;
	public final generatedBytes:Int64;
	public final sentBytes:Int64;
	public final stalls:Int64;
	public final malformedSegments:Int;
	public final gcSamples:Int;
	public final threads:Map<Int, String>;
	public final gcStats:Array<ProfileGcStats>;
	public final timelineSamples:Array<ProfileTimelineSample>;
	public final allocationSamples:Array<ProfileAllocationSample>;
	public final nativeSymbolCount:Int;
	public final lastError:Null<String>;

	public function new(session:ProfilerSession) {
		state = session.state;
		samples = session.samples;
		instrumentedCalls = session.instrumentedCalls;
		unresolvedFrames = session.unresolvedFrames;
		functions = session.functionAggregates();
		lines = session.lineAggregates();
		stacks = session.stackAggregates();
		events = session.events.copy();
		leaves = session.leaves.copy();
		metadataChanges = session.metadataChanges.copy();
		metadataSchema = session.metadata == null ? 0 : session.metadata.schema;
		metadataRevisions = session.metadata == null ? new Map() : session.metadata.revisions.copy();
		bufferCapacity = session.bufferCapacity;
		bufferUsed = session.bufferUsed;
		bufferUtilization = session.bufferUtilization;
		requestedSampleRate = session.requestedSampleRate;
		metadataRefreshMs = session.metadataRefreshMs;
		sampleRecords = session.sampleRecords;
		generatedBytes = session.generatedBytes;
		sentBytes = session.sentBytes;
		stalls = session.stalls;
		malformedSegments = session.malformedSegments;
		gcSamples = session.gcSamples;
		threads = session.threads.copy();
		gcStats = session.gcStats.copy();
		timelineSamples = session.timelineSamples.copy();
		allocationSamples = session.allocationSamples.copy();
		nativeSymbolCount = session.nativeSymbolCount();
		lastError = session.lastError;
	}
}

/** Owns profiler lifecycle, incremental decoding, symbolization and aggregation. */
class ProfilerSession {
	public static inline final EVENT_MODULE_REVISION = 0x484C0001;
	public static inline final EVENT_THREAD_NAME = 0x484C0002;
	public static inline final EVENT_GC_STATS = 0x484C0003;
	public static inline final EVENT_NATIVE_SYMBOL = 0x484C0004;
	public static inline final EVENT_ALLOCATION_SAMPLE = 0x484C0005;

	public var state(default, null):ProfilerSessionState = Connected;
	public var samples(default, null) = 0;
	public var instrumentedCalls(default, null) = 0;
	public var unresolvedFrames(default, null) = 0;
	public var bufferCapacity(default, null):Int64 = Int64.ofInt(0);
	public var bufferUsed(default, null):Int64 = Int64.ofInt(0);
	public var bufferUtilization(default, null):Float = 0;
	public var requestedSampleRate(default, null) = 0;
	public var metadataRefreshMs(default, null):Float = 0;
	public var sampleRecords(default, null):Int64 = Int64.ofInt(0);
	public var generatedBytes(default, null):Int64 = Int64.ofInt(0);
	public var sentBytes(default, null):Int64 = Int64.ofInt(0);
	public var stalls(default, null):Int64 = Int64.ofInt(0);
	public var malformedSegments(default, null) = 0;
	public var sources(default, null) = 0;
	public var gcSamples(default, null) = 0;
	public final threads = new Map<Int, String>();
	public final gcStats:Array<ProfileGcStats> = [];
	public final timelineSamples:Array<ProfileTimelineSample> = [];
	public final allocationSamples:Array<ProfileAllocationSample> = [];
	public var timelineCapacity:Int = 50000;
	public var allocationCapacity:Int = 10000;

	static inline final CHUNK_BYTES = 256 * 1024;

	var timelineSequence = 0;
	var allocationSequence = 0;
	final nativeSymbols = new Map<String, {name:String, module:String, base:Int64}>();

	public var metadata(default, null):Null<HldiMetadata>;
	public var lastError(default, null):Null<String>;
	public final events:Array<ProfileEvent> = [];
	public final leaves:Array<ProfileLeaf> = [];
	public final metadataChanges:Array<ProfileMetadataChange> = [];
	public var leafCapacity:Int = 256;
	public var eventCapacity:Int = 256;

	final client:HldiClient;
	var capture:Null<HlpcCapture>;
	var capturePath:Null<String>;
	var clock = new HldiClock();
	final functions = new Map<String, ProfileAggregate>();
	final lines = new Map<String, ProfileAggregate>();
	final stacks = new Map<String, ProfileStack>();
	var sampleRate = 1000;
	var metadataReceived = false;
	var endSeen = false;
	var latestTime = 0.0;
	// The frames that describe a session, kept so a capture begun mid-session can start with them.
	var sessionFrame:Null<HldiFrame>;
	var clockFrame:Null<HldiFrame>;
	var threadsFrame:Null<HldiFrame>;

	public function new(client:HldiClient)
		this.client = client;

	/**
		Starts a session and waits for the metadata it pushes first. `sources` defaults to sampling, plus allocation
		sampling when `allocationInterval` is set.
	**/
	public function start(sampleRate:Int = 1000, allocationInterval:Int = 0, ?sources:Int):Void {
		if (state == Closed)
			throw "Profiler session is closed";
		if (state == Running)
			pause();
		this.sampleRate = sampleRate;
		this.sources = sources != null ? sources : HldiClient.SOURCE_SAMPLING | (allocationInterval > 0 ? HldiClient.SOURCE_ALLOC : 0);
		requestedSampleRate = sampleRate;
		// Ticks restart with each session; its timestamps continue from where the last one stopped.
		clock = new HldiClock();
		clock.offsetSeconds = latestTime;
		metadataReceived = false;
		endSeen = false;
		var started = false;
		try {
			if (capturePath != null && capture == null)
				capture = new HlpcCapture(capturePath, client.hello.processId, sampleRate, this.sources);
			updateStatus(client.start(this.sources, sampleRate, allocationInterval));
			started = true;
			state = Running;
			lastError = null;
			var deadline = Timer.stamp() + 10.0;
			while (!metadataReceived) {
				var frame = client.nextFrame(0.1);
				if (frame != null)
					handle(frame);
				if (endSeen)
					throw "The runtime ended the profiling session before it started";
				if (Timer.stamp() > deadline)
					throw "The runtime did not push symbol metadata";
			}
		} catch (error:Dynamic) {
			lastError = Std.string(error);
			state = Failed;
			// The runtime's session is stopped, and the capture file closed incomplete; the capture stays requested, so the
			// next start records it again. Neither hides the error.
			try {
				if (started)
					client.stop();
			} catch (_:Dynamic) {}
			try {
				if (capture != null)
					capture.close(false);
			} catch (_:Dynamic) {}
			capture = null;
			throw error;
		}
	}

	/** Stops the session and consumes everything it recorded. */
	public function pause():Void {
		if (state != Running)
			return;
		try {
			updateStatus(client.stop());
			drainQueued();
		} catch (error:Dynamic) {
			lastError = Std.string(error);
			state = Failed;
			throw error;
		}
		state = Paused;
	}

	/**
		Consumes the frames the runtime has pushed, waiting up to `waitSeconds` for the first. Returns after about
		`maxBytes` of frames. Throws if the connection fails or the runtime ends the session.
	**/
	public function poll(maxBytes:Int = 1024 * 1024, waitSeconds:Float = 0.0):Int {
		if (state != Running)
			return 0;
		try {
			var records = 0, bytes = 0, frame = client.nextFrame(waitSeconds);
			while (frame != null) {
				bytes += frame.payload.length;
				records += handle(frame);
				if (bytes >= maxBytes || endSeen)
					break;
				frame = client.nextFrame(0.0);
			}
			if (endSeen)
				throw "The runtime ended the profiling session";
			lastError = null;
			return records;
		} catch (error:Dynamic) {
			lastError = Std.string(error);
			state = Failed;
			throw error;
		}
	}

	public function snapshot():ProfilerSnapshot
		return new ProfilerSnapshot(this);

	public function reset():Void {
		samples = 0;
		instrumentedCalls = 0;
		unresolvedFrames = 0;
		functions.clear();
		lines.clear();
		stacks.clear();
		events.resize(0);
		leaves.resize(0);
		metadataChanges.resize(0);
		gcStats.resize(0);
		timelineSamples.resize(0);
		allocationSamples.resize(0);
		timelineSequence = 0;
		allocationSequence = 0;
		nativeSymbols.clear();
		gcSamples = 0;
	}

	public function close():Void {
		if (state == Closed)
			return;
		try
			pause()
		catch (_:Dynamic) {}
		stopCapture();
		client.close();
		state = Closed;
	}

	/**
		Records the session's pushed frames to an HLPC v2 capture. Before `start` the capture begins with the next
		session; while one runs it begins with the frames that describe it. A capture ends with its session.
	**/
	public function startCapture(path:String):Void {
		if (capturePath != null)
			throw "Profiler capture is already active";
		capturePath = path;
		if (state != Running)
			return;
		capture = new HlpcCapture(path, client.hello.processId, sampleRate, sources);
		if (sessionFrame != null)
			capture.frame(sessionFrame);
		capture.metadata(client.metadataBytes());
		if (clockFrame != null)
			capture.frame(clockFrame);
		if (threadsFrame != null)
			capture.frame(threadsFrame);
	}

	/** Closes the capture. It is complete only if its session ended while it was recording. */
	public function stopCapture():Void {
		if (capture != null)
			capture.close(false);
		capture = null;
		capturePath = null;
	}

	public function captureActive():Bool
		return capturePath != null;

	public function nativeSymbolCount():Int {
		var count = 0;
		for (_ in nativeSymbols)
			count++;
		return count;
	}

	function drainQueued():Void {
		var frame = client.nextFrame(0.0);
		while (frame != null) {
			handle(frame);
			frame = client.nextFrame(0.0);
		}
	}

	function updateStatus(status:profiler.HldiTypes.HldiStatus):Void
		updateBuffers(status.chunks, status.chunksInUse);

	function updateBuffers(chunks:Int, chunksInUse:Int):Void {
		bufferCapacity = Int64.mul(Int64.ofInt(chunks), Int64.ofInt(CHUNK_BYTES));
		bufferUsed = Int64.mul(Int64.ofInt(chunksInUse), Int64.ofInt(CHUNK_BYTES));
		bufferUtilization = chunks == 0 ? 0 : chunksInUse / chunks;
	}

	/** Applies one pushed frame and returns the records it held. */
	function handle(frame:HldiFrame):Int {
		if (capture != null) {
			capture.frame(frame);
			if (frame.type == HldiFrames.PUSH_END) {
				capture.close(true);
				capture = null;
				capturePath = null;
			}
		}
		switch frame.type {
			case HldiFrames.PUSH_METADATA:
				applyMetadata(frame.payload);
			case HldiFrames.PUSH_SESSION:
				var info = HldiFrames.session(frame.payload);
				clock.nominalHz = Std.parseFloat(Int64.toStr(info.nominalHz));
				sessionFrame = frame;
			case HldiFrames.PUSH_CLOCK:
				clock.add(HldiFrames.clock(frame.payload));
				clockFrame = frame;
			case HldiFrames.PUSH_THREADS:
				for (thread in HldiFrames.threads(frame.payload))
					threads.set(thread.id, thread.name);
				threadsFrame = frame;
			case HldiFrames.PUSH_STATS:
				var stats = HldiFrames.stats(frame.payload);
				updateBuffers(stats.chunkCount, stats.chunksInUse);
				stalls = stats.stalls;
				sentBytes = stats.sentBytes;
			case HldiFrames.PUSH_END:
				endSeen = true;
			case HldiFrames.PUSH_DATA:
				return handleData(frame);
			default:
		}
		return 0;
	}

	function handleData(frame:HldiFrame):Int {
		var records;
		try {
			var data = HldiFrames.data(frame.payload);
			records = HldiFrames.records(clock, data.threadId, data.records);
			generatedBytes = Int64.add(generatedBytes, Int64.ofInt(data.rawLength));
		} catch (_:Dynamic) {
			malformedSegments++;
			return 0;
		}
		for (record in records)
			consume(record);
		return records.length;
	}

	function applyMetadata(payload:Bytes):Void {
		var previous = metadata, started = Timer.stamp(), next = profiler.HldiCodec.metadata(payload);
		metadataRefreshMs = (Timer.stamp() - started) * 1000;
		if (previous != null)
			for (moduleId => revision in next.revisions) {
				var oldRevision = previous.revisions.get(moduleId);
				if (oldRevision != null && oldRevision != revision)
					metadataChanges.push(new ProfileMetadataChange(latestTime, moduleId, oldRevision, revision));
			}
		metadata = next;
		metadataReceived = true;
	}

	public function functionAggregates():Array<ProfileAggregate>
		return sorted(functions);

	public function lineAggregates():Array<ProfileAggregate>
		return sorted(lines);

	public function stackAggregates():Array<ProfileStack> {
		var result = [for (value in stacks) value];
		result.sort((left, right) -> right.samples - left.samples);
		return result;
	}

	function consume(record:HldiRecord):Void {
		if (record.timestamp > latestTime)
			latestTime = record.timestamp;
		if (record.kind == HldiFrames.KIND_ENTER) {
			instrumentedCalls++;
			var symbol = resolve(record.frames[0]);
			if (symbol != null)
				functionAggregate(symbol).calls++;
			return;
		}
		if (record.kind == HldiFrames.KIND_EVENT) {
			events.push(new ProfileEvent(record.timestamp, record.threadId, record.value, record.payload));
			if (eventCapacity <= 0)
				events.resize(0);
			else if (events.length > eventCapacity)
				events.splice(0, events.length - eventCapacity);
			// The runtime pushes the metadata for a new module revision, so EVENT_MODULE_REVISION needs no refresh.
			if (record.value == EVENT_THREAD_NAME)
				threads.set(record.threadId, record.payload.toString());
			if (record.value == EVENT_GC_STATS && record.payload.length == 40) {
				var input = new HldiReader(record.payload);
				gcStats.push(new ProfileGcStats(record.timestamp, input.u64(), input.u64(), input.u64(), input.u64(), input.u64()));
				if (gcStats.length > 256)
					gcStats.shift();
			}
			if (record.value == EVENT_NATIVE_SYMBOL && record.payload.length >= 24) {
				var input = new HldiReader(record.payload),
					pc = Int64.toStr(input.u64()),
					base = input.u64();
				var moduleLength = input.u32(), symbolLength = input.u32();
				// Lengths are unsigned on the wire: one past 2^31 reads negative here.
				if (moduleLength >= 0 && symbolLength >= 0 && moduleLength <= input.remaining() && symbolLength == input.remaining() - moduleLength) {
					var module = input.take(moduleLength).toString(),
						name = input.take(symbolLength).toString();
					nativeSymbols.set(pc, {name: name, module: module, base: base});
				}
			}
			if (record.value == EVENT_ALLOCATION_SAMPLE && record.payload.length >= 32 && (record.payload.length - 32) % 8 == 0) {
				var input = new HldiReader(record.payload),
					requested = input.u64(),
					allocated = input.u64(),
					interval = input.u32(),
					typeKind = input.u32(),
					count = input.u32();
				input.u32();
				if (count == Std.int(input.remaining() / 8)) {
					var frames = [for (_ in 0...count) input.u64()];
					allocationSamples.push(new ProfileAllocationSample(++allocationSequence, record.timestamp, record.threadId, requested, allocated,
						interval, typeKind, resolveFrames(frames)));
					if (allocationSamples.length > allocationCapacity)
						allocationSamples.splice(0, allocationSamples.length - allocationCapacity);
				}
			}
			return;
		}
		samples++;
		sampleRecords = Int64.add(sampleRecords, Int64.ofInt(1));
		if (record.flags & 1 != 0)
			gcSamples++;
		if (!threads.exists(record.threadId))
			threads.set(record.threadId, 'Thread ${record.threadId}');
		if (record.frames.length != 0)
			captureLeaf(record);
		var resolved:Array<{symbol:HldiSymbol, line:Null<HldiSourceLine>}> = [];
		for (address in record.frames) {
			var symbol = resolve(address);
			if (symbol == null) {
				if (!nativeSymbols.exists(Int64.toStr(address)))
					unresolvedFrames++;
				continue;
			}
			resolved.push({symbol: symbol, line: symbol.sourceAt(address)});
		}
		for (index in 0...resolved.length) {
			var frame = resolved[index],
				aggregate = functionAggregate(frame.symbol);
			aggregate.totalSamples++;
			if (index == 0)
				aggregate.selfSamples++;
			if (frame.line != null) {
				var line = lineAggregate(frame.symbol, frame.line);
				line.totalSamples++;
				if (index == 0)
					line.selfSamples++;
			}
		}
		if (record.frames.length != 0) {
			var frameDetails = resolveFrames(record.frames);
			var key = [for (frame in frameDetails) frame.key].join(";"),
				stack = stacks.get(key);
			if (stack == null) {
				stack = new ProfileStack(key, frameDetails);
				stacks.set(key, stack);
			}
			stack.samples++;
			var threadSamples = stack.threadSamples.get(record.threadId);
			stack.threadSamples.set(record.threadId, (threadSamples == null ? 0 : threadSamples) + 1);
			timelineSamples.push(new ProfileTimelineSample(++timelineSequence, record.timestamp, record.threadId, key));
			if (timelineCapacity <= 0)
				timelineSamples.resize(0);
			else if (timelineSamples.length > timelineCapacity)
				timelineSamples.splice(0, timelineSamples.length - timelineCapacity);
		}
	}

	function resolveFrames(frames:Array<Int64>):Array<ProfileStackFrame> {
		var frameDetails = [];
		for (index in 0...frames.length) {
			var address = frames[frames.length - index - 1],
				symbol = resolve(address);
			var location = symbol == null ? null : symbol.sourceAt(address),
				native = nativeSymbols.get(Int64.toStr(address));
			frameDetails.push(symbol == null ? new ProfileStackFrame(native == null ? "[native/unknown]" : 'native:${native.module}:${native.name}',
				native == null ? "[native/unknown]" : 'native:${native.module}:${native.name}', native == null ? "[native/unknown]" : native.name, 0, null,
				null, native == null ? null : native.module,
				native == null ? null : Int64.toStr(Int64.sub(address,
					native.base))) : new ProfileStackFrame('${symbol.moduleId}:${symbol.revision}:${symbol.functionId}',
					'${symbol.moduleId}:${symbol.functionId}', symbol.name, symbol.revision, location == null ? null : location.file,
					location == null ? null : location.line));
		}
		return frameDetails;
	}

	function captureLeaf(record:HldiRecord):Void {
		var address = record.frames[0], symbol = resolve(address);
		if (symbol == null)
			leaves.push(new ProfileLeaf(record.timestamp, record.threadId, address));
		else {
			var relative = Int64.sub(address, symbol.start),
				offset:Null<Int> = relative.high == 0 ? relative.low : null,
				location = symbol.sourceAt(address);
			leaves.push(location == null ? new ProfileLeaf(record.timestamp, record.threadId, address, offset,
				symbol.name) : new ProfileLeaf(record.timestamp, record.threadId, address, offset, symbol.name, location.opcodeIndex, location.opcode,
					location.file, location.line));
		}
		if (leafCapacity <= 0)
			leaves.resize(0);
		else if (leaves.length > leafCapacity)
			leaves.splice(0, leaves.length - leafCapacity);
	}

	function resolve(address:Int64):Null<HldiSymbol> {
		if (metadata == null)
			return null;
		var values = metadata.symbols, low = 0, high = values.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (Int64.ucompare(values[middle].start, address) <= 0)
				low = middle + 1;
			else
				high = middle;
		}
		return low != 0 && Int64.ucompare(address, values[low - 1].end) < 0 ? values[low - 1] : null;
	}

	function functionAggregate(symbol:HldiSymbol):ProfileAggregate {
		var key = '${symbol.moduleId}:${symbol.revision}:${symbol.functionId}',
			value = functions.get(key);
		if (value == null) {
			value = new ProfileAggregate(key, '${symbol.moduleId}:${symbol.functionId}', symbol.name);
			functions.set(key, value);
		}
		return value;
	}

	function lineAggregate(symbol:HldiSymbol, source:HldiSourceLine):ProfileAggregate {
		var key = '${symbol.moduleId}:${symbol.revision}:${symbol.functionId}:${source.file}:${source.line}',
			value = lines.get(key);
		if (value == null) {
			value = new ProfileAggregate(key, '${symbol.moduleId}:${symbol.functionId}:${source.file}:${source.line}', symbol.name, source.file, source.line);
			lines.set(key, value);
		}
		return value;
	}

	static function sorted(values:Map<String, ProfileAggregate>):Array<ProfileAggregate> {
		var result = [for (value in values) value];
		result.sort((left, right) -> left.selfSamples != right.selfSamples ? right.selfSamples - left.selfSamples : left.totalSamples != right.totalSamples ? right.totalSamples - left.totalSamples : right.calls - left.calls);
		return result;
	}
}
