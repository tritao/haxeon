struct ManagedNarrow {
	public var text:String;
	public var unsigned:UInt8;
	public var signed:Int16;
	public var small:Int8;
	public var wide:UInt16;
	public function new(text:String) {
		this.text = text;
		unsigned = 0;
		signed = 0;
		small = 0;
		wide = 0;
	}
	public function setValues():Void {
		unsigned = cast 257;
		signed = cast 65535;
		small = cast 255;
		wide = cast 65537;
	}
}

class ManagedNarrowHolder {
	public var value:ManagedNarrow;
	public var optional:Null<ManagedNarrow>;
	public function new() { value = new ManagedNarrow("held"); }
}

struct ManagedLong {
	public var text:String;
	public var signed:CLong;
	public var unsigned:CULong;
	public function new() {
		text = "long";
		signed = cast haxe.Int64.ofInt(0);
		unsigned = cast haxe.Int64.ofInt(0);
	}
}

class ManagedLongHolder {
	public var value:ManagedLong;
	public function new() value = new ManagedLong();
}

function localRoundTrip(value:Int):Int {
	var local = new ManagedNarrow("local");
	local.unsigned = cast value;
	return cast local.unsigned;
}

function holderRoundTrip(holder:ManagedNarrowHolder, value:Int):Int {
	holder.value.signed = cast value;
	return cast holder.value.signed;
}

function main():Int {
	var holder = new ManagedNarrowHolder();
	holder.value.setValues();
	if ((cast holder.value.unsigned:Int) != 1 || (cast holder.value.signed:Int) != -1
		|| (cast holder.value.small:Int) != -1 || (cast holder.value.wide:Int) != 1) return 1;
	holder.value.unsigned = cast 255;
	holder.value.unsigned = cast ((cast holder.value.unsigned:Int) + 1);
	holder.value.signed = cast 32767;
	holder.value.signed = cast ((cast holder.value.signed:Int) + 1);
	if ((cast holder.value.unsigned:Int) != 0 || (cast holder.value.signed:Int) != -32768) return 2;
	var copy = holder.value;
	copy.setValues();
	if (holder.value.text != "held" || (cast holder.value.unsigned:Int) != 0 || (cast copy.signed:Int) != -1) return 3;
	holder.optional = new ManagedNarrow("held");
	if (holder.optional != null) holder.optional.setValues();
	var optional = holder.optional;
	if (optional == null || optional.text != "held" || (cast optional.small:Int) != -1 || (cast optional.wide:Int) != 1) return 4;
	var values:Array<ManagedNarrow> = [copy];
	values[0].unsigned = cast 258;
	if ((cast values[0].unsigned:Int) != 2 || (cast copy.unsigned:Int) != 1) return 5;
	if (localRoundTrip(257) != 1 || holderRoundTrip(holder, 65535) != -1) return 6;
	var longHolder = new ManagedLongHolder();
	longHolder.value.signed = cast haxe.Int64.make(1, -1);
	longHolder.value.unsigned = cast haxe.Int64.make(1, -1);
	#if (wasm || managed_long32)
	var expectedSigned = haxe.Int64.ofInt(-1);
	var expectedUnsigned = haxe.Int64.make(0, -1);
	#else
	var expectedSigned = haxe.Int64.make(1, -1);
	var expectedUnsigned = haxe.Int64.make(1, -1);
	#end
	if (haxe.Int64.compare(cast longHolder.value.signed, expectedSigned) != 0
		|| haxe.Int64.compare(cast longHolder.value.unsigned, expectedUnsigned) != 0) return 7;
	return 42;
}
