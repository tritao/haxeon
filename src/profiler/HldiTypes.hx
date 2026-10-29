package profiler;

import haxe.Int64;
import haxe.io.Bytes;

class HldiHello {
	public final version:Int;
	public final capabilities:Int;
	public final runtimeVersion:Int;
	public final processId:Int;

	public function new(version:Int, capabilities:Int, runtimeVersion:Int, processId:Int) {
		this.version = version;
		this.capabilities = capabilities;
		this.runtimeVersion = runtimeVersion;
		this.processId = processId;
	}
}

class HldiStatus {
	public final active:Bool;
	public final sources:Int;
	public final chunks:Int;
	public final chunksInUse:Int;
	public final dataFrames:Int64;
	public final rawBytes:Int64;

	public function new(active:Bool, sources:Int, chunks:Int, chunksInUse:Int, dataFrames:Int64, rawBytes:Int64) {
		this.active = active;
		this.sources = sources;
		this.chunks = chunks;
		this.chunksInUse = chunksInUse;
		this.dataFrames = dataFrames;
		this.rawBytes = rawBytes;
	}
}

/** A frame the runtime pushed (flag bit 2). */
class HldiFrame {
	public final type:Int;
	public final flags:Int;
	public final payload:Bytes;

	public function new(type:Int, flags:Int, payload:Bytes) {
		this.type = type;
		this.flags = flags;
		this.payload = payload;
	}
}

class HldiSessionInfo {
	public final version:Int;
	public final sources:Int;
	public final tickKind:Int;
	public final baseTicks:Int64;
	public final nominalHz:Int64;

	public function new(version:Int, sources:Int, tickKind:Int, baseTicks:Int64, nominalHz:Int64) {
		this.version = version;
		this.sources = sources;
		this.tickKind = tickKind;
		this.baseTicks = baseTicks;
		this.nominalHz = nominalHz;
	}
}

class HldiClockPair {
	public final ticks:Int64;
	public final monotonicNs:Int64;
	public final unixNs:Int64;

	public function new(ticks:Int64, monotonicNs:Int64, unixNs:Int64) {
		this.ticks = ticks;
		this.monotonicNs = monotonicNs;
		this.unixNs = unixNs;
	}
}

class HldiDataFrame {
	public final threadId:Int;
	public final flags:Int;
	public final rawLength:Int;

	/** The thread's records, decompressed. */
	public final records:Bytes;

	public function new(threadId:Int, flags:Int, rawLength:Int, records:Bytes) {
		this.threadId = threadId;
		this.flags = flags;
		this.rawLength = rawLength;
		this.records = records;
	}
}

class HldiStats {
	public final chunksInUse:Int;
	public final chunkCount:Int;
	public final stalls:Int64;
	public final stallTicks:Int64;
	public final rawBytes:Int64;
	public final sentBytes:Int64;

	public function new(chunksInUse:Int, chunkCount:Int, stalls:Int64, stallTicks:Int64, rawBytes:Int64, sentBytes:Int64) {
		this.chunksInUse = chunksInUse;
		this.chunkCount = chunkCount;
		this.stalls = stalls;
		this.stallTicks = stallTicks;
		this.rawBytes = rawBytes;
		this.sentBytes = sentBytes;
	}
}

class HldiSourceLine {
	public final offset:Int;
	public final endOffset:Int;
	public final opcodeIndex:Int;
	public final opcode:Int;
	public final file:String;
	public final line:Int;

	public function new(offset:Int, endOffset:Int, opcodeIndex:Int, opcode:Int, file:String, line:Int) {
		this.offset = offset;
		this.endOffset = endOffset;
		this.opcodeIndex = opcodeIndex;
		this.opcode = opcode;
		this.file = file;
		this.line = line;
	}
}

class HldiSymbol {
	public final moduleId:Int64;
	public final revision:Int;
	public final functionId:Int;
	public final start:Int64;
	public final end:Int64;
	public final name:String;
	public final lines:Array<HldiSourceLine>;

	public function new(moduleId:Int64, revision:Int, functionId:Int, start:Int64, end:Int64, name:String, lines:Array<HldiSourceLine>) {
		this.moduleId = moduleId;
		this.revision = revision;
		this.functionId = functionId;
		this.start = start;
		this.end = end;
		this.name = name;
		this.lines = lines;
	}

	public function sourceAt(address:Int64):Null<HldiSourceLine> {
		var relative = Int64.sub(address, start), low = 0, high = lines.length;
		if (relative.high != 0)
			return null;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (haxe.Int32.ucompare(lines[middle].offset, relative.low) <= 0)
				low = middle + 1;
			else
				high = middle;
		}
		if (low == 0)
			return null;
		var location = lines[low - 1];
		return location.endOffset != 0 && haxe.Int32.ucompare(relative.low, location.endOffset) >= 0 ? null : location;
	}
}

class HldiMetadata {
	public final schema:Int;
	public final symbols:Array<HldiSymbol>;
	public final revisions:Map<String, Int>;

	public function new(schema:Int, symbols:Array<HldiSymbol>, revisions:Map<String, Int>) {
		this.schema = schema;
		this.symbols = symbols;
		this.revisions = revisions;
	}
}

class HldiRecord {
	public final kind:Int;
	public final flags:Int;
	public final timestamp:Float;
	public final threadId:Int;
	public final value:Int;
	public final frames:Array<Int64>;
	public final payload:Bytes;

	public function new(kind:Int, flags:Int, timestamp:Float, threadId:Int, value:Int, frames:Array<Int64>, payload:Bytes) {
		this.kind = kind;
		this.flags = flags;
		this.timestamp = timestamp;
		this.threadId = threadId;
		this.value = value;
		this.frames = frames;
		this.payload = payload;
	}
}
