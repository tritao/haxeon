import runtime.memory.Arena;
import runtime.memory.RawPtr;

@:value @:repr("C")
class NativeNode {
	public var tag:UInt8;
	public var value:Int64;
	public var ratio:Float32;
	public var next:RawPtr<NativeNode>;
}

function main():Int {
	if (sizeof<NativeNode>() != 32 || alignof<NativeNode>() != 8 || offsetof<NativeNode>("value") != 8 || offsetof<NativeNode>("ratio") != 16
		|| offsetof<NativeNode>("next") != 24)
		return 1;
	var arena = new Arena(32);
	var nodes:RawPtr<NativeNode> = arena.alloc(2);
	var tag:RawPtr<UInt8> = nodes.byteOffset(offsetof<NativeNode>("tag")).castTo();
	var value:RawPtr<Int64> = nodes.byteOffset(offsetof<NativeNode>("value")).castTo();
	var ratio:RawPtr<Float32> = nodes.byteOffset(offsetof<NativeNode>("ratio")).castTo();
	var next:RawPtr<RawPtr<NativeNode>> = nodes.byteOffset(offsetof<NativeNode>("next")).castTo();
	tag.store(7);
	value.store(9001);
	ratio.store(1.25);
	next.store(nodes.offset(1));
	var second:RawPtr<NativeNode> = nodes.offset(1);
	var secondTag:RawPtr<UInt8> = second.byteOffset(offsetof<NativeNode>("tag")).castTo();
	secondTag.store(9);
	var firstTag = tag.load();
	var firstValue = value.load();
	var firstRatio = ratio.load();
	var link = next.load();
	var secondTagValue = secondTag.load();
	var linkTag:RawPtr<UInt8> = link.byteOffset(offsetof<NativeNode>("tag")).castTo();
	var empty:RawPtr<Int> = RawPtr.nullPtr();
	var correct = firstTag == 7 && firstValue == 9001 && firstRatio == 1.25 && secondTagValue == 9 && !link.isNull() && linkTag.load() == 9 && empty.isNull();
	var ints:RawPtr<Int32> = arena.alloc(4);
	ints.offset(0).store(11);
	ints.offset(1).store(22);
	ints.offset(2).store(33);
	ints.offset(3).store(44);
	correct = correct && ints.offset(0).load() == 11 && ints.offset(1).load() == 22 && ints.offset(2).load() == 33 && ints.offset(3).load() == 44;
	correct = correct && tag.load() == 7 && secondTag.load() == 9 && value.load() == 9001 && ratio.load() == 1.25;
	arena.reset();
	var reused:RawPtr<Int32> = arena.alloc();
	reused.store(42);
	correct = correct && reused.load() == 42;
	arena.dispose();
	arena.dispose();
	return correct ? 42 : 1;
}
