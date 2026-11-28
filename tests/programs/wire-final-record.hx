import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;
import haxeon.wire.JsonWire;
import haxeon.wire.JsonWireWriter;
import haxeon.wire.MessagePack;
import haxeon.wire.MessagePackWriter;

@:wire class WireFinalChild {
	public static var constructions:Int = 0;

	@:id(1) public final value:Int;

	public function new(value:Int) {
		constructions++;
		this.value = value;
	}
}

@:wire class WireFinalRecord {
	public static var constructions:Int = 0;

	@:id(1) public final label:String;
	@:id(2) public var count:Int = 7;
	@:id(3) @:optional public final note:Null<String>;
	@:id(4) public final child:WireFinalChild;

	public function new(label:String, note:Null<String>, child:WireFinalChild) {
		constructions++;
		this.label = label;
		this.note = note;
		this.child = child;
	}
}

@:wire class WireFinalDefaults {
	public static var constructions:Int = 0;

	@:id(1) public final label:String = "default";
	@:id(2) public var count:Int = 7;
	@:id(3) @:optional public final note:Null<String>;
	@:id(4) public final tags:Array<Int> = [2, 3];

	public function new() {
		constructions++;
		note = null;
	}
}

class WireFinalCalls {
	public static var evaluations:Int = 0;

	public static function label():String {
		evaluations++;
		return "camera";
	}
}

@:wire class WireFinalObservable implements Observable {
	@:id(1) public final label:String;

	public function new(label:String)
		this.label = label;
}

function main():Int {
	var original = new WireFinalRecord(WireFinalCalls.label(), null, new WireFinalChild(42));
	original.count = 9;
	var json = JsonWire.encode(original);
	var jsonResult:WireFinalRecord = JsonWire.decode<WireFinalRecord>(json).unwrap();
	if (jsonResult.label != "camera" || jsonResult.note != null || jsonResult.count != 9
		|| jsonResult.child.value != 42)
		return 1;
	var binary = MessagePack.encode(original);
	var binaryResult:WireFinalRecord =
		MessagePack.decode<WireFinalRecord>(binary).unwrap();
	if (binaryResult.label != "camera" || binaryResult.note != null || binaryResult.count != 9
		|| binaryResult.child.value != 42)
		return 2;
	if (WireFinalRecord.constructions != 1 || WireFinalChild.constructions != 1 || WireFinalCalls.evaluations != 1)
		return 3;
	var observableBytes = JsonWire.encode(new WireFinalObservable("observed"));
	var effect = new Effect(() -> {});
	var observed:WireFinalObservable = null;
	ReactiveRuntime.withTracking(effect, () -> {
		observed = JsonWire.decode<WireFinalObservable>(observableBytes).unwrap();
	});
	effect.dispose();
	if (observed.label != "observed")
		return 9;
	var partial = new MessagePackWriter();
	partial.writeMapHeader(1);
	partial.writeInt(2);
	partial.writeInt(10);
	var defaults:WireFinalDefaults =
		MessagePack.decode<WireFinalDefaults>(partial.getBytes()).unwrap();
	if (defaults.label != "default"
		|| defaults.count != 10
		|| defaults.note != null
		|| defaults.tags.length != 2
		|| defaults.tags[0] != 2)
		return 4;
	var jsonPartial = new JsonWireWriter();
	jsonPartial.writeMapHeader(2);
	jsonPartial.writeFieldKey(2, "count");
	jsonPartial.writeInt(9);
	jsonPartial.writeFieldKey(2, "count");
	jsonPartial.writeInt(10);
	var jsonDefaults:WireFinalDefaults =
		JsonWire.decode<WireFinalDefaults>(jsonPartial.getString()).unwrap();
	if (jsonDefaults.label != "default" || jsonDefaults.count != 10 || jsonDefaults.note != null
		|| jsonDefaults.tags.length != 2 || jsonDefaults.tags[0] != 2)
		return 6;
	defaults.tags[0] = 99;
	if (jsonDefaults.tags[0] != 2 || WireFinalDefaults.constructions != 0)
		return 8;
	var jsonMissing = new JsonWireWriter();
	jsonMissing.writeMapHeader(0);
	try {
		var absentJson:WireFinalRecord =
			JsonWire.decode<WireFinalRecord>(jsonMissing.getString()).unwrap();
		return 7;
	} catch (_:Dynamic) {}
	var missing = new MessagePackWriter();
	missing.writeMapHeader(0);
	try {
		var absent:WireFinalRecord =
			MessagePack.decode<WireFinalRecord>(missing.getBytes()).unwrap();
		return 5;
	} catch (_:Dynamic) {}
	return 42;
}
