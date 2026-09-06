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
	public final first:Int64;
	public final next:Int64;
	public final dropped:Int64;
	public final sampleRate:Int;
	public final paused:Bool;

	public function new(first:Int64, next:Int64, dropped:Int64, sampleRate:Int, paused:Bool) {
		this.first = first;
		this.next = next;
		this.dropped = dropped;
		this.sampleRate = sampleRate;
		this.paused = paused;
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

class HldiReadResult {
	public final next:Int64;
	public final dropped:Int64;
	public final bytes:Bytes;

	public function new(next:Int64, dropped:Int64, bytes:Bytes) {
		this.next = next;
		this.dropped = dropped;
		this.bytes = bytes;
	}
}
