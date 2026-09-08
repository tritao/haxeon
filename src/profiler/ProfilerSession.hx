package profiler;

import haxe.Int64;
import haxe.Timer;
import haxe.io.Bytes;
import profiler.HldiCodec.HldiStreamDecoder;
import profiler.HldiCodec.HldiReader;
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
	public final unresolvedFrames:Int;
	public final dropped:Int64;
	public final functions:Array<ProfileAggregate>;
	public final lines:Array<ProfileAggregate>;
	public final stacks:Array<ProfileStack>;
	public final events:Array<ProfileEvent>;
	public final leaves:Array<ProfileLeaf>;
	public final metadataChanges:Array<ProfileMetadataChange>;
	public final metadataSchema:Int;
	public final metadataRevisions:Map<String, Int>;
	public final pendingBytes:Int;
	public final bufferCapacity:Int64;
	public final bufferUsed:Int64;
	public final bufferUtilization:Float;
	public final requestedSampleRate:Int;
	public final effectiveSampleRate:Int;
	public final metadataRefreshMs:Float;
	public final sampleRecords:Int64;
	public final generatedBytes:Int64;
	public final overheadMicrosPerSample:Float;
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
		unresolvedFrames = session.unresolvedFrames;
		dropped = session.dropped;
		functions = session.functionAggregates();
		lines = session.lineAggregates();
		stacks = session.stackAggregates();
		events = session.events.copy();
		leaves = session.leaves.copy();
		metadataChanges = session.metadataChanges.copy();
		metadataSchema = session.metadata == null ? 0 : session.metadata.schema;
		metadataRevisions = session.metadata == null ? new Map() : session.metadata.revisions.copy();
		pendingBytes = session.pendingBytes();
		bufferCapacity = session.bufferCapacity;
		bufferUsed = session.bufferUsed;
		bufferUtilization = session.bufferUtilization;
		requestedSampleRate = session.requestedSampleRate;
		effectiveSampleRate = session.effectiveSampleRate;
		metadataRefreshMs = session.metadataRefreshMs;
		sampleRecords = session.sampleRecords;
		generatedBytes = session.generatedBytes;
		overheadMicrosPerSample = session.overheadMicrosPerSample;
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
	public var unresolvedFrames(default, null) = 0;
	public var dropped(default, null):Int64 = Int64.ofInt(0);
	public var bufferCapacity(default, null):Int64 = Int64.ofInt(0);
	public var bufferUsed(default, null):Int64 = Int64.ofInt(0);
	public var bufferUtilization(default, null):Float = 0;
	public var requestedSampleRate(default, null) = 0;
	public var effectiveSampleRate(default, null) = 0;
	public var metadataRefreshMs(default, null):Float = 0;
	public var sampleRecords(default, null):Int64 = Int64.ofInt(0);
	public var generatedBytes(default, null):Int64 = Int64.ofInt(0);
	public var overheadMicrosPerSample(default, null):Float = 0;
	public var gcSamples(default, null) = 0;
	public final threads = new Map<Int, String>();
	public final gcStats:Array<ProfileGcStats> = [];
	public final timelineSamples:Array<ProfileTimelineSample> = [];
	public final allocationSamples:Array<ProfileAllocationSample> = [];
	public var timelineCapacity:Int = 50000;
	public var allocationCapacity:Int = 10000;

	var timelineSequence = 0;
	var allocationSequence = 0;
	var allocationInterval = 0;
	final nativeSymbols = new Map<String, {name:String, module:String, base:Int64}>();

	public var metadata(default, null):Null<HldiMetadata>;
	public var lastError(default, null):Null<String>;
	public var metadataRefreshSeconds:Float = 5.0;
	public final events:Array<ProfileEvent> = [];
	public final leaves:Array<ProfileLeaf> = [];
	public final metadataChanges:Array<ProfileMetadataChange> = [];
	public var leafCapacity:Int = 256;
	public var eventCapacity:Int = 256;

	final client:HldiClient;
	var capture:Null<HlpcCapture>;
	final decoder = new HldiStreamDecoder();
	final functions = new Map<String, ProfileAggregate>();
	final lines = new Map<String, ProfileAggregate>();
	final stacks = new Map<String, ProfileStack>();
	var cursor:Int64 = Int64.ofInt(0);
	var sampleRate = 1000;
	var nextMetadataRefresh = 0.0;

	public function new(client:HldiClient)
		this.client = client;

	public function start(sampleRate:Int = 1000, allocationInterval:Int = 0):Void {
		if (state == Closed)
			throw "Profiler session is closed";
		this.sampleRate = sampleRate;
		this.allocationInterval = allocationInterval;
		refreshMetadata();
		var status = client.configure(sampleRate, true, allocationInterval);
		updateHealth(status);
		cursor = status.next;
		dropped = status.dropped;
		state = Running;
		lastError = null;
	}

	public function pause():Void {
		if (state != Running)
			return;
		var status = client.configure(sampleRate, false, 0);
		updateHealth(status);
		cursor = status.next;
		dropped = status.dropped;
		state = Paused;
	}

	public function poll(maxBytes:Int = 256 * 1024):Int {
		if (state != Running && state != Paused)
			return 0;
		try {
			if (metadataRefreshSeconds > 0 && Timer.stamp() >= nextMetadataRefresh)
				refreshMetadata();
			var requested = cursor, result = client.read(cursor, maxBytes);
			if (capture != null)
				capture.samples(requested, result.next, result.dropped, result.bytes);
			cursor = result.next;
			dropped = result.dropped;
			var records = decoder.append(result.bytes);
			for (record in records)
				consume(record);
			updateHealth(client.status());
			lastError = null;
			return records.length;
		} catch (error:Dynamic) {
			lastError = Std.string(error);
			state = Failed;
			throw error;
		}
	}

	public function refreshMetadata(?timestamp:Float):Void {
		var previous = metadata,
			started = Timer.stamp(),
			bytes = client.metadataBytes(),
			next = profiler.HldiCodec.metadata(bytes);
		if (capture != null)
			capture.metadata(bytes);
		metadataRefreshMs = (Timer.stamp() - started) * 1000;
		if (previous != null)
			for (moduleId => revision in next.revisions) {
				var oldRevision = previous.revisions.get(moduleId);
				if (oldRevision != null && oldRevision != revision)
					metadataChanges.push(new ProfileMetadataChange(timestamp == null ? Timer.stamp() : timestamp, moduleId, oldRevision, revision));
			}
		metadata = next;
		nextMetadataRefresh = Timer.stamp() + metadataRefreshSeconds;
	}

	public function snapshot():ProfilerSnapshot
		return new ProfilerSnapshot(this);

	public function reset():Void {
		samples = 0;
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

	public function pendingBytes():Int
		return decoder.pendingBytes();

	public function startCapture(path:String):Void {
		if (capture != null)
			throw "Profiler capture is already active";
		capture = new HlpcCapture(path, client.hello.processId, sampleRate);
		capture.metadata(client.metadataBytes());
	}

	public function stopCapture():Void {
		if (capture == null)
			return;
		capture.close(cursor, dropped);
		capture = null;
	}

	public function captureActive():Bool
		return capture != null;

	public function nativeSymbolCount():Int {
		var count = 0;
		for (_ in nativeSymbols)
			count++;
		return count;
	}

	function updateHealth(status:profiler.HldiTypes.HldiStatus):Void {
		dropped = status.dropped;
		bufferCapacity = status.bufferCapacity;
		bufferUsed = Int64.sub(status.next, status.consumer);
		requestedSampleRate = status.requestedRate;
		effectiveSampleRate = status.sampleRate;
		sampleRecords = status.sampleRecords;
		generatedBytes = status.generatedBytes;
		overheadMicrosPerSample = status.sampleRecords == 0 ? 0 : Std.parseFloat(Int64.toStr(status.sampleNanos)) / Std.parseFloat(Int64.toStr(status.sampleRecords)) / 1000;
		bufferUtilization = bufferCapacity == 0 ? 0 : Std.parseFloat(Int64.toStr(bufferUsed)) / Std.parseFloat(Int64.toStr(bufferCapacity));
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
		if (record.kind == 2) {
			events.push(new ProfileEvent(record.timestamp, record.threadId, record.value, record.payload));
			if (eventCapacity <= 0)
				events.resize(0);
			else if (events.length > eventCapacity)
				events.splice(0, events.length - eventCapacity);
			if (record.value == EVENT_MODULE_REVISION) {
				if (record.payload.length != 12)
					throw "Invalid HLDI module revision event";
				var announced = new HldiReader(record.payload),
					moduleId = Int64.toStr(announced.u64()),
					revision = announced.u32();
				refreshMetadata(record.timestamp);
				if (metadata == null || metadata.revisions.get(moduleId) != revision)
					throw 'HLDI metadata did not reach announced module revision $revision';
			}
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
				if (moduleLength + symbolLength == input.remaining()) {
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
		result.sort((left, right) -> left.selfSamples == right.selfSamples ? right.totalSamples - left.totalSamples : right.selfSamples - left.selfSamples);
		return result;
	}
}
