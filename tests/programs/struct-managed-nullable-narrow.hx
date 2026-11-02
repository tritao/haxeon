struct NullableNarrow {
 public var text:String;
 public var u8:Null<UInt8>;
 public var i16:Null<Int16>;
 public var i8:Null<Int8>;
 public var u16:Null<UInt16>;
 public function new() {
  text = "value"; u8 = null; i16 = null; i8 = null; u16 = null;
 }
 public function set():Void {
  u8 = cast 257; i16 = cast 65535; i8 = cast 255; u16 = cast 65537;
 }
}
class NullableNarrowHolder {
 public var value:NullableNarrow;
 public var optional:Null<NullableNarrow>;
 public function new() { value = new NullableNarrow(); optional = null; }
}
struct NullableLong {
 public var text:String;
 public var signed:Null<CLong>;
 public var unsigned:Null<CULong>;
 public function new() { text = "long"; signed = null; unsigned = null; }
}
function valid(value:NullableNarrow):Bool {
 return value.text == "value" && (cast value.u8:Int) == 1 && (cast value.i16:Int) == -1
  && (cast value.i8:Int) == -1 && (cast value.u16:Int) == 1;
}
function main():Int {
 var holder = new NullableNarrowHolder();
 if (holder.value.u8 != null || holder.optional != null) return 1;
 holder.value.set();
 if (!valid(holder.value)) return 2;
 var copy = holder.value;
 copy.u8 = null;
 if (copy.u8 != null || !valid(holder.value)) return 3;
 holder.optional = holder.value;
 if (holder.optional == null || !valid(holder.optional)) return 4;
 if (holder.optional != null) holder.optional.u8 = cast 258;
 var optional = holder.optional;
 if (optional == null || (cast optional.u8:Int) != 2 || !valid(holder.value)) return 5;
 var values:Array<NullableNarrow> = [holder.value];
 values[0].i8 = cast 254;
 if ((cast values[0].i8:Int) != -2 || !valid(holder.value)) return 6;
 var longValue = new NullableLong();
 longValue.signed = cast haxe.Int64.make(1, -1);
 longValue.unsigned = cast haxe.Int64.make(1, -1);
 #if (wasm || managed_long32)
 var expectedSigned = haxe.Int64.ofInt(-1);
 var expectedUnsigned = haxe.Int64.make(0, -1);
 #else
 var expectedSigned = haxe.Int64.make(1, -1);
 var expectedUnsigned = haxe.Int64.make(1, -1);
 #end
 if (haxe.Int64.compare(cast longValue.signed, expectedSigned) != 0
  || haxe.Int64.compare(cast longValue.unsigned, expectedUnsigned) != 0) return 7;
 #if !wasm
 var canonical:Null<UInt8> = cast 1;
 holder.value.u8 = canonical;
 var allocated = hl.Gc.totalAllocated();
 for (_ in 0...10000) holder.value.u8 = canonical;
 if (hl.Gc.totalAllocated() != allocated) return 8;
 #end
 return 42;
}
