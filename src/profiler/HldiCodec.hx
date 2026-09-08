package profiler;

import haxe.Int64;
import haxe.io.Bytes;
import haxe.io.FPHelper;
import profiler.HldiTypes.HldiMetadata;
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

class HldiStreamDecoder {
	var pending = Bytes.alloc(0);

	public function new() {}

	public function append(chunk:Bytes):Array<HldiRecord> {
		var combined = Bytes.alloc(pending.length + chunk.length);
		combined.blit(0, pending, 0, pending.length);
		combined.blit(pending.length, chunk, 0, chunk.length);
		var records = [], position = 0;
		while (combined.length - position >= 4) {
			var prefix = new HldiReader(combined.sub(position, combined.length - position)),
				bodyLength = prefix.u32();
			if (bodyLength < 20 || bodyLength > 8 * 1024 * 1024)
				throw 'Invalid HLDI record length $bodyLength';
			if (combined.length - position < bodyLength + 4)
				break;
			var input = new HldiReader(combined.sub(position + 4, bodyLength)),
				kind = input.u8(),
				flags = input.u8();
			input.u16();
			var timestamp = input.f64(),
				threadId = input.u32(),
				value = input.u32(),
				frames:Array<Int64> = [],
				payload = Bytes.alloc(0);
			if (kind == 1) {
				if (value < 0 || input.remaining() != value * 8)
					throw 'Invalid HLDI sample frame count $value';
				for (_ in 0...value)
					frames.push(input.u64());
			} else if (kind == 2)
				payload = input.take(input.remaining());
			else
				throw 'Unknown HLDI profiler record kind $kind';
			records.push(new HldiRecord(kind, flags, timestamp, threadId, value, frames, payload));
			position += bodyLength + 4;
		}
		pending = combined.sub(position, combined.length - position);
		return records;
	}

	public function pendingBytes():Int
		return pending.length;
}
