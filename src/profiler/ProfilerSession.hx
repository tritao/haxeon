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
	public final frames:Array<String>;
	public var samples = 0;

	public function new(frames:Array<String>)
		this.frames = frames;
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
		lastError = session.lastError;
	}
}

/** Owns profiler lifecycle, incremental decoding, symbolization and aggregation. */
class ProfilerSession {
	public static inline final EVENT_MODULE_REVISION = 0x484C0001;
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
	public var metadata(default, null):Null<HldiMetadata>;
	public var lastError(default, null):Null<String>;
	public var metadataRefreshSeconds:Float = 5.0;
	public final events:Array<ProfileEvent> = [];
	public final leaves:Array<ProfileLeaf> = [];
	public final metadataChanges:Array<ProfileMetadataChange> = [];
	public var leafCapacity:Int = 256;
	public var eventCapacity:Int = 256;

	final client:HldiClient;
	final decoder = new HldiStreamDecoder();
	final functions = new Map<String, ProfileAggregate>();
	final lines = new Map<String, ProfileAggregate>();
	final stacks = new Map<String, ProfileStack>();
	var cursor:Int64 = Int64.ofInt(0);
	var sampleRate = 1000;
	var nextMetadataRefresh = 0.0;

	public function new(client:HldiClient)
		this.client = client;

	public function start(sampleRate:Int = 1000):Void {
		if (state == Closed)
			throw "Profiler session is closed";
		this.sampleRate = sampleRate;
		refreshMetadata();
		var status = client.configure(sampleRate, true);
		updateHealth(status);
		cursor = status.next;
		dropped = status.dropped;
		state = Running;
		lastError = null;
	}

	public function pause():Void {
		if (state != Running)
			return;
		var status = client.configure(sampleRate, false);
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
			var result = client.read(cursor, maxBytes);
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
		var previous = metadata, started = Timer.stamp(), next = client.metadata();
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
	}

	public function close():Void {
		if (state == Closed)
			return;
		try pause() catch (_:Dynamic) {}
		client.close();
		state = Closed;
	}

	public function pendingBytes():Int
		return decoder.pendingBytes();

	function updateHealth(status:profiler.HldiTypes.HldiStatus):Void {
		dropped = status.dropped;
		bufferCapacity = status.bufferCapacity;
		bufferUsed = Int64.sub(status.next, status.consumer);
		requestedSampleRate = status.requestedRate;
		effectiveSampleRate = status.sampleRate;
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
				var announced = new HldiReader(record.payload), moduleId = Int64.toStr(announced.u64()), revision = announced.u32();
				refreshMetadata(record.timestamp);
				if (metadata == null || metadata.revisions.get(moduleId) != revision)
					throw 'HLDI metadata did not reach announced module revision $revision';
			}
			return;
		}
		samples++;
		if (record.frames.length != 0)
			captureLeaf(record);
		var resolved:Array<{symbol:HldiSymbol, line:Null<HldiSourceLine>}> = [];
		for (address in record.frames) {
			var symbol = resolve(address);
			if (symbol == null) {
				unresolvedFrames++;
				continue;
			}
			resolved.push({symbol: symbol, line: symbol.sourceAt(address)});
		}
		for (index in 0...resolved.length) {
			var frame = resolved[index], aggregate = functionAggregate(frame.symbol);
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
			var labels = [];
			for (index in 0...record.frames.length) {
				var address = record.frames[record.frames.length - index - 1], symbol = resolve(address);
				labels.push(symbol == null ? "[unknown]" : symbol.name);
			}
			var key = labels.join(";") , stack = stacks.get(key);
			if (stack == null) {
				stack = new ProfileStack(labels);
				stacks.set(key, stack);
			}
			stack.samples++;
		}
	}

	function captureLeaf(record:HldiRecord):Void {
		var address = record.frames[0], symbol = resolve(address);
		if (symbol == null)
			leaves.push(new ProfileLeaf(record.timestamp, record.threadId, address));
		else {
			var relative = Int64.sub(address, symbol.start), offset:Null<Int> = relative.high == 0 ? relative.low : null,
				location = symbol.sourceAt(address);
			leaves.push(location == null
				? new ProfileLeaf(record.timestamp, record.threadId, address, offset, symbol.name)
				: new ProfileLeaf(record.timestamp, record.threadId, address, offset, symbol.name, location.opcodeIndex, location.opcode, location.file, location.line));
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
		var key = '${symbol.moduleId}:${symbol.revision}:${symbol.functionId}', value = functions.get(key);
		if (value == null) {
			value = new ProfileAggregate(key, '${symbol.moduleId}:${symbol.functionId}', symbol.name);
			functions.set(key, value);
		}
		return value;
	}

	function lineAggregate(symbol:HldiSymbol, source:HldiSourceLine):ProfileAggregate {
		var key = '${symbol.moduleId}:${symbol.revision}:${symbol.functionId}:${source.file}:${source.line}', value = lines.get(key);
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
