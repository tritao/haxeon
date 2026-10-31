import runtime.memory.Arena;
import runtime.memory.NativeSpan;
import runtime.memory.RawPtr;

struct FlatLeaf {
  public var tag:UInt8;
  public var delta:Int16;
  public var ratio:Float32;
}

struct FlatPacket {
  public var prefix:Int32;
  public var child:FlatLeaf;
  public var count:Int32;
}

struct FlatIntLeaf {
  public var count:Int;
}

struct FlatIntRoot {
  public var child:FlatIntLeaf;
}

class PointerCounter {
  public var calls:Int = 0;
  final pointer:RawPtr<FlatIntRoot>;
  public function new(pointer:RawPtr<FlatIntRoot>) this.pointer = pointer;
  public function next():RawPtr<FlatIntRoot> {
    calls++;
    return pointer;
  }
}

class NativeSpanHolder < T > {
  final span:NativeSpan<T>;

  public function new(span:NativeSpan<T>) {
    this.span = span;
  }

  public function nativeSpan():NativeSpan < T > return span;
}

class NativeSpanComponent < T > {
  public final span:NativeSpan<T>;

  public function new(span:NativeSpan<T>) {
    this.span = span;
  }
}

class NativeSpanColumn < T > {
  final span:NativeSpan<T>;

  public function new(span:NativeSpan<T>) {
    this.span = span;
  }

  public function nativeSpan():NativeSpan < T > return span;
}

class NativeSpanQuery {
  public function nativeSpans<T
    >(component:NativeSpanComponent<T>):Array < NativeSpanColumn < T>> return [new NativeSpanColumn<T>(component.span)];
}

function roundTrip<T>(pointer:RawPtr<T>, value:T):T {
  pointer.store(value);
  return pointer.load();
}

function main():Int {
  if (sizeof<FlatLeaf>() != 8 || alignof<FlatLeaf>() != 4 || offsetof<FlatLeaf>("delta") != 2
    || offsetof<FlatLeaf>("ratio") != 4 || sizeof<FlatPacket>() != 16 || alignof<FlatPacket>() != 4
    || offsetof<FlatPacket>("child") != 4 || offsetof<FlatPacket>("count") != 12) return 1;
  var arena = new Arena(64),
    pointer:RawPtr<FlatPacket> = arena.alloc(2), leaf = new FlatLeaf(), packet = new FlatPacket();
  leaf.tag = 250;
  leaf.delta = -1234;
  leaf.ratio = 1.5;
  packet.prefix = -321;
  packet.child = leaf;
  packet.count = 17;
  var result = roundTrip(pointer, packet);
  pointer.ref.prefix = -654;
  pointer.ref.child.delta = 2345;
  pointer.ref.child.ratio = 3.25;
  var intPointer:RawPtr<FlatIntRoot> = arena.alloc(1);
  intPointer.ref.child.count = 13;
  var oldCount = intPointer.ref.child.count++;
  if (oldCount != 13 || intPointer.load().child.count != 14) return 2;
  if (intPointer.ref.child.count-- != 14 || intPointer.load().child.count != 13) return 3;
  var counter = new PointerCounter(intPointer);
  if (counter.next().ref.child.count++ != 13 || counter.calls != 1 || intPointer.load().child.count != 14) return 4;
  var projected:FlatPacket = pointer.ref;
  var span:NativeSpan<FlatPacket> = new NativeSpan<FlatPacket>(pointer,
    2), component = new NativeSpanComponent<FlatPacket>(span),
    query = new NativeSpanQuery(), secondPacket = new FlatPacket(),
    secondPointer:RawPtr<FlatPacket> = query.nativeSpans(component)[0].nativeSpan().at(1);
  secondPacket.prefix = 8;
  secondPacket.count = 33;
  secondPointer.store(secondPacket);
  secondPointer.ref.child.tag = 33;
  var capturedSpanRead:Void -> FlatPacket = function():FlatPacket return span.get(1),
    capturedPacket = capturedSpanRead();
  packet.count = 99;
  var stored:FlatPacket = pointer.load(), storedSecond:FlatPacket = secondPointer.load();
  var correct = result.prefix == -321 && result.child.tag == 250 && result.child.delta == -1234 && result.child.ratio
    == 1.5 && result.count == 17 && projected.prefix == -654 && projected.child.tag == 250 && projected.child.delta
    == 2345 && projected.child.ratio == 3.25 && projected.count == 17 && stored.prefix == -654 && stored.child.tag
    == 250 && stored.child.delta == 2345 && stored.child.ratio == 3.25 && stored.count == 17 && storedSecond.prefix == 8
    && storedSecond.child.tag == 33 && storedSecond.count == 33 && capturedPacket.count == 33;
  result.count = 42;
  correct = correct && pointer.load().count == 17;
  arena.dispose();
  return correct ? 42 : 1;
}
