package profiler;

import haxe.Int64;
import haxe.Timer;
import haxe.io.Bytes;
import profiler.HldiCodec.HldiStreamDecoder;
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
	public final name:String;
	public final file:Null<String>;
	public final line:Null<Int>;
	public var selfSamples = 0;
	public var totalSamples = 0;

	public function new(key:String, name:String, ?file:String, ?line:Int) {
		this.key = key;
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

class ProfilerSnapshot {
	public final state:ProfilerSessionState;
	public final samples:Int;
	public final unresolvedFrames:Int;
	public final dropped:Int64;
	public final functions:Array<ProfileAggregate>;
	public final lines:Array<ProfileAggregate>;
	public final stacks:Array<ProfileStack>;
	public final events:Array<ProfileEvent>;
	public final metadataSchema:Int;
	public final metadataRevisions:Map<String, Int>;
	public final pendingBytes:Int;
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
		metadataSchema = session.metadata == null ? 0 : session.metadata.schema;
		metadataRevisions = session.metadata == null ? new Map() : session.metadata.revisions.copy();
		pendingBytes = session.pendingBytes();
		lastError = session.lastError;
	}
}

/** Owns profiler lifecycle, incremental decoding, symbolization and aggregation. */
class ProfilerSession {
	public var state(default, null):ProfilerSessionState = Connected;
	public var samples(default, null) = 0;
	public var unresolvedFrames(default, null) = 0;
	public var dropped(default, null):Int64 = Int64.ofInt(0);
	public var metadata(default, null):Null<HldiMetadata>;
	public var lastError(default, null):Null<String>;
	public var metadataRefreshSeconds:Float = 5.0;
	public final events:Array<ProfileEvent> = [];

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
		cursor = status.next;
		dropped = status.dropped;
		state = Running;
		lastError = null;
	}

	public function pause():Void {
		if (state != Running)
			return;
		var status = client.configure(sampleRate, false);
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
			lastError = null;
			return records.length;
		} catch (error:Dynamic) {
			lastError = Std.string(error);
			state = Failed;
			throw error;
		}
	}

	public function refreshMetadata():Void {
		metadata = client.metadata();
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
			return;
		}
		samples++;
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
			value = new ProfileAggregate(key, symbol.name);
			functions.set(key, value);
		}
		return value;
	}

	function lineAggregate(symbol:HldiSymbol, source:HldiSourceLine):ProfileAggregate {
		var key = '${symbol.moduleId}:${symbol.revision}:${symbol.functionId}:${source.file}:${source.line}', value = lines.get(key);
		if (value == null) {
			value = new ProfileAggregate(key, symbol.name, source.file, source.line);
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
