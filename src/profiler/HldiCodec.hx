package profiler;

import haxe.Int64;
import haxe.io.Bytes;
import haxe.io.FPHelper;
import profiler.HldiTypes.HldiClockPair;
import profiler.HldiTypes.HldiDataFrame;
import profiler.HldiTypes.HldiMetadata;
import profiler.HldiTypes.HldiSessionInfo;
import profiler.HldiTypes.HldiStats;
import profiler.HldiTypes.HldiRecord;
import profiler.HldiTypes.HldiSourceLine;
import profiler.HldiTypes.HldiSymbol;

class HldiReader {
	public final bytes:Bytes;
	public var position(default, null):Int = 0;

	public function new(bytes:Bytes)
		this.bytes = bytes;

	public function remaining():Int
		return bytes.length - position;

	public function u8():Int {
		require(1);
		return bytes.get(position++);
	}

	public function u16():Int {
		var low = u8();
		return low | (u8() << 8);
	}

	public function u32():Int {
		require(4);
		var value = bytes.get(position) | (bytes.get(position + 1) << 8) | (bytes.get(position + 2) << 16) | (bytes.get(position + 3) << 24);
		position += 4;
		return value;
	}

	public function u64():Int64 {
		var low = u32(), high = u32();
		return Int64.make(high, low);
	}

	public function f64():Float {
		var low = u32(), high = u32();
		return FPHelper.i64ToDouble(low, high);
	}

	public function take(length:Int):Bytes {
		require(length);
		var result = bytes.sub(position, length);
		position += length;
		return result;
	}

	public function skip(length:Int):Void {
		require(length);
		position += length;
	}

	function require(length:Int):Void {
		if (length < 0 || length > remaining())
			throw 'Truncated HLDI payload at $position (need $length, have ${remaining()})';
	}
}

class HldiCodec {
	public static function metadata(bytes:Bytes):HldiMetadata {
		var input = new HldiReader(bytes), schema = input.u32();
		if (schema < 1 || schema > 4)
			throw 'Unsupported HLDI metadata schema $schema';
		var moduleCount = count(input, "modules"), symbols = [], revisions = new Map<String, Int>();
		for (_ in 0...moduleCount) {
			var moduleId = input.u64(),
				revision = input.u32(),
				regionCount = count(input, "regions"),
				files:Array<String> = [];
			revisions.set(Int64.toStr(moduleId), revision);
			if (schema >= 2)
				for (_ in 0...count(input, "debug files"))
					files.push(input.take(count(input, "debug file bytes")).toString());
			for (_ in 0...regionCount) {
				var base = input.u64(),
					regionSize = input.u64(),
					flags = input.u32(),
					regionRevision = schema >= 4 ? input.u32() : revision,
					functionCount = count(input, "functions");
				for (_ in 0...functionCount) {
					var functionId = input.u32(),
						offset = input.u32(),
						size = input.u32(),
						name = input.take(count(input, "symbol name bytes")).toString();
					if (size <= 0)
						throw 'Invalid empty HLDI symbol $name';
					var lines:Array<HldiSourceLine> = [];
					if (schema >= 2)
						for (_ in 0...count(input, "source lines")) {
							var jitOffset = input.u32(),
								endOffset = schema >= 3 ? input.u32() : 0;
							var opcodeIndex = schema >= 3 ? input.u32() : 0,
								opcode = schema >= 3 ? input.u32() : 0;
							var fileId = input.u32(), line = input.u32();
							if (jitOffset < 0
								|| jitOffset >= size
								|| (schema >= 3 && (endOffset <= jitOffset || endOffset > size))
								|| fileId < 0
								|| fileId >= files.length
								|| line <= 0)
								throw 'Invalid source mapping for $name';
							if (lines.length != 0 && haxe.Int32.ucompare(jitOffset, lines[lines.length - 1].offset) < 0)
								throw 'Unsorted source mapping for $name';
							lines.push(new HldiSourceLine(jitOffset, endOffset, opcodeIndex, opcode, files[fileId], line));
						}
					var start = Int64.add(base, Int64.ofInt(offset)),
						end = Int64.add(start, Int64.ofInt(size));
					symbols.push(new HldiSymbol(moduleId, regionRevision, functionId, start, end, name, lines));
				}
			}
		}
		if (input.remaining() != 0)
			throw 'Trailing HLDI metadata bytes: ${input.remaining()}';
		symbols.sort((left, right) -> Int64.ucompare(left.start, right.start));
		return new HldiMetadata(schema, symbols, revisions);
	}

	static function count(input:HldiReader, what:String):Int {
		var value = input.u32();
		if (value < 0 || value > 10000000)
			throw 'Invalid HLDI $what count $value';
		return value;
	}
}

/** Converts record ticks to seconds by interpolating between the clock pairs the runtime pushes. */
class HldiClock {
	final pairTicks:Array<Int64> = [];
	final pairNanos:Array<Int64> = [];
	var originNanos:Int64 = Int64.ofInt(0);

	public var nominalHz:Float = 0;

	/** Added to every result, so a later session's timestamps can continue an earlier one's. */
	public var offsetSeconds:Float = 0;

	public function new() {}

	public function pairs():Int
		return pairTicks.length;

	public function add(pair:HldiClockPair):Void {
		if (pairTicks.length != 0) {
			if (Int64.ucompare(pair.ticks, pairTicks[pairTicks.length - 1]) <= 0)
				return;
		} else
			originNanos = pair.monotonicNs;
		pairTicks.push(pair.ticks);
		pairNanos.push(pair.monotonicNs);
	}

	/** Seconds since the first clock pair, extrapolated past the ends. */
	public function seconds(ticks:Int64):Float
		return offsetSeconds + elapsed(ticks);

	function elapsed(ticks:Int64):Float {
		var count = pairTicks.length;
		if (count == 0)
			return nominalHz > 0 ? signed(ticks) / nominalHz : signed(ticks) / 1e9;
		if (count == 1) {
			var rate = nominalHz > 0 ? 1e9 / nominalHz : 1.0;
			return (signed(Int64.sub(pairNanos[0], originNanos)) + signed(Int64.sub(ticks, pairTicks[0])) * rate) / 1e9;
		}
		var low = 0, high = count;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (Int64.ucompare(pairTicks[middle], ticks) <= 0)
				low = middle + 1;
			else
				high = middle;
		}
		if (low == 0)
			low = 1;
		if (low >= count)
			low = count - 1;
		var rate = signed(Int64.sub(pairNanos[low], pairNanos[low - 1])) / signed(Int64.sub(pairTicks[low], pairTicks[low - 1]));
		return (signed(Int64.sub(pairNanos[low - 1], originNanos)) + signed(Int64.sub(ticks, pairTicks[low - 1])) * rate) / 1e9;
	}

	static function signed(value:Int64):Float {
		var low:Float = value.low;
		if (low < 0)
			low += 4294967296.0;
		return value.high * 4294967296.0 + low;
	}
}

/** Decodes the frames HLDI v2 pushes and the per-thread records inside its data frames. */
class HldiFrames {
	public static inline final PUSH_METADATA = 4;
	public static inline final PUSH_SESSION = 16;
	public static inline final PUSH_DATA = 17;
	public static inline final PUSH_CLOCK = 18;
	public static inline final PUSH_THREADS = 19;
	public static inline final PUSH_END = 20;
	public static inline final PUSH_STATS = 21;

	public static inline final DATA_COMPRESSED = 1;

	public static inline final RECORD_ENTER = 0x01;
	public static inline final RECORD_EXIT = 0x02;
	public static inline final RECORD_UNWIND = 0x03;
	public static inline final RECORD_SPAN_BEGIN = 0x10;
	public static inline final RECORD_SPAN_END = 0x11;
	public static inline final RECORD_FRAME_MARK = 0x12;
	public static inline final RECORD_FRAME_IDLE = 0x13;
	public static inline final RECORD_EVENT = 0x20;
	public static inline final RECORD_COUNTER = 0x21;
	public static inline final RECORD_SAMPLE = 0x22;
	public static inline final RECORD_STALL = 0x30;

	/** HldiRecord kinds this decoder produces. */
	public static inline final KIND_SAMPLE = 1;

	public static inline final KIND_EVENT = 2;
	public static inline final KIND_ENTER = 3;

	public static function session(payload:Bytes):HldiSessionInfo {
		var input = new HldiReader(payload),
			version = input.u32(),
			sources = input.u32(),
			tickKind = input.u32();
		input.u32();
		return new HldiSessionInfo(version, sources, tickKind, input.u64(), input.u64());
	}

	public static function clock(payload:Bytes):HldiClockPair {
		var input = new HldiReader(payload);
		return new HldiClockPair(input.u64(), input.u64(), input.u64());
	}

	public static function threads(payload:Bytes):Array<{id:Int, name:String}> {
		var input = new HldiReader(payload), count = input.u32(), result = [];
		if (count < 0 || count > 1000000)
			throw 'Invalid HLDI thread count $count';
		for (_ in 0...count) {
			var id = input.u32();
			result.push({id: id, name: input.take(input.u32()).toString()});
		}
		return result;
	}

	public static function stats(payload:Bytes):HldiStats {
		var input = new HldiReader(payload),
			inUse = input.u32(),
			count = input.u32();
		return new HldiStats(inUse, count, input.u64(), input.u64(), input.u64(), input.u64());
	}

	static inline final MAX_DATA_LENGTH = 256 << 20;

	/** A data frame's thread and records, decompressed when the frame says so. */
	public static function data(payload:Bytes):HldiDataFrame {
		var input = new HldiReader(payload),
			threadId = input.u32(),
			flags = input.u32(),
			rawLength = input.u32();
		input.u32();
		// The runtime pushes one chunk's records at a time; a larger length is malformed, not an allocation to make.
		if (rawLength < 0 || rawLength > MAX_DATA_LENGTH)
			throw 'Invalid HLDI data frame length $rawLength';
		var records;
		if (flags & DATA_COMPRESSED != 0)
			records = Lz4.decompressBlock(payload, 16, payload.length - 16, rawLength);
		else {
			if (payload.length - 16 != rawLength)
				throw "HLDI data frame length does not match its payload";
			records = payload.sub(16, rawLength);
		}
		return new HldiDataFrame(threadId, flags, rawLength, records);
	}

	/** Samples, events and instrumented-call entries from one thread's records; the other kinds are validated and skipped. */
	public static function records(clock:HldiClock, threadId:Int, bytes:Bytes):Array<HldiRecord> {
		var input = new HldiReader(bytes),
			result:Array<HldiRecord> = [],
			empty = Bytes.alloc(0);
		while (input.remaining() > 0) {
			var low = input.u32(),
				high = input.u32(),
				kind = high >>> 24,
				time = clock.seconds(Int64.make(high & 0xFFFFFF, low));
			switch kind {
				case RECORD_ENTER:
					result.push(new HldiRecord(KIND_ENTER, 0, time, threadId, 0, [input.u64()], empty));
				case RECORD_EXIT, RECORD_SPAN_END:
				case RECORD_UNWIND, RECORD_FRAME_MARK, RECORD_FRAME_IDLE, RECORD_STALL:
					input.skip(8);
				case RECORD_SPAN_BEGIN:
					var units = input.u32(), encoding = input.u32();
					input.skip(padded(units * (encoding == 1 ? 1 : 2)));
				case RECORD_EVENT:
					var id = input.u32(),
						length = input.u32(),
						payload = input.take(length);
					input.skip(padded(length) - length);
					result.push(new HldiRecord(KIND_EVENT, 0, time, threadId, id, [], payload));
				case RECORD_COUNTER:
					input.skip(8);
					var units = input.u32(), encoding = input.u32();
					input.skip(padded(units * (encoding == 1 ? 1 : 2)));
				case RECORD_SAMPLE:
					var sampleThread = input.u32(),
						frames = input.u16(),
						flags = input.u8();
					input.u8();
					result.push(new HldiRecord(KIND_SAMPLE, flags, time, sampleThread, frames, [for (_ in 0...frames) input.u64()], empty));
				default:
					throw 'Unknown HLDI record kind $kind';
			}
		}
		return result;
	}

	static function padded(length:Int):Int {
		if (length < 0)
			throw 'Invalid HLDI record length $length';
		return (length + 7) & ~7;
	}
}
