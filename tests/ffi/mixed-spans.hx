import haxe.io.Bytes;
import runtime.memory.Arena;
import runtime.memory.NativeSpan;
import runtime.memory.RawPtr;
import MixedSpans;

function main():Int {
	var arena = new Arena(), data = Bytes.alloc(3);
	var pointer:RawPtr<UInt8> = arena.alloc(2);
	data.set(0, 11); data.set(1, 22); data.set(2, 33);
	pointer.store(44); pointer.offset(1).store(55);
	var records = new NativeSpan<UInt8>(pointer, 2);
	var result = MixedSpans.check_records_span(data, records);
	arena.dispose();
	return result == 42 ? 42 : 1;
}
