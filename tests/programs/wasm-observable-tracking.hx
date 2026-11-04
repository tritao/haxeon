import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;

struct ValueRecord implements Equatable {
	public final value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:ValueRecord):Bool return value == other.value;
}

class BaseModel implements Observable {
	public var baseValue:Int;
	public function new(value:Int) this.baseValue = value;
}

class EqualValue implements Equatable {
	public final value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:EqualValue):Bool return value == other.value;
}

class IdentityValue {
	public final value:Int;
	public function new(value:Int) this.value = value;
}

class FreshModel implements Observable {
	public var value:Int;
	public function new() initialize(5);
	public function initialize(next:Int) value = next;
}

class Model extends BaseModel {
	public var count:Int;
	public var other:Int;
	public var item:EqualValue;
	public var valueRecord:ValueRecord;
	public var optionalRecord:Null<ValueRecord>;
	public var ratio:Float;
	public var optionalLabel:Null<String>;
	public var identity:IdentityValue;
	public function new() {
		super(4);
		count = 1;
		other = 2;
		item = new EqualValue(7);
		valueRecord = new ValueRecord(10);
		optionalRecord = null;
		ratio = 0.0;
		optionalLabel = null;
		identity = new IdentityValue(5);
	}
}

class ConstructorMutation {
	public function new(model:Model) model.other = 9;
}

enum ObservablePhase implements Equatable { Idle; Busy(value:Int); }

class EnumModel implements Observable {
	public var phase:ObservablePhase;
	public function new() phase = Idle;
}

@:wire class WireModel implements Observable {
	@:id(1) public var label:String;
	@:id(2) @:optional public var note:Null<String>;
	public function new() {
		label = "start";
		note = null;
	}
}

function fail(code:Int):Int {
	Sys.exit(code);
	return code;
}

function main():Int {
	var model = new Model();
	var baseValue = 0, countValue = 0, otherValue = 0;
	var itemValue:EqualValue = null;
	var valueRecordValue:ValueRecord = new ValueRecord(0);
	var optionalRecordValue:Null<ValueRecord> = null;
	var ratioValue = 0.0;
	var labelValue:Null<String> = null;
	var identityValue:IdentityValue = null;
	var freshEffectValue = 0;
	var freshSignalEffectValue = 0;
	var base = new Effect(function() { baseValue = model.baseValue; });
	var count = new Effect(function() { countValue = model.count; });
	var other = new Effect(function() { otherValue = model.other; });
	var item = new Effect(function() { itemValue = model.item; });
	var valueRecord = new Effect(function() { valueRecordValue = model.valueRecord; });
	var optionalRecord = new Effect(function() { optionalRecordValue = model.optionalRecord; });
	var ratio = new Effect(function() { ratioValue = model.ratio; });
	var label = new Effect(function() { labelValue = model.optionalLabel; });
	var identity = new Effect(function() { identityValue = model.identity; });
	var freshEffect = new Effect(function() {
		var fresh = new FreshModel();
		fresh.initialize(6);
		freshEffectValue = fresh.value;
	});
	var freshDerived = new haxeon.reactive.Derived<Int>(function() {
		var fresh = new FreshModel();
		fresh.initialize(7);
		return fresh.value;
	});
	var freshSignalEffect = new Effect(function() {
		var fresh = new Signal<Int>(1);
		fresh.update(6);
		freshSignalEffectValue = fresh.value;
	});
	var freshSignalDerived = new haxeon.reactive.Derived<Int>(function() {
		var fresh = new Signal<Int>(1);
		fresh.update(7);
		return fresh.value;
	});
	if (baseValue != 4 || countValue != 1 || otherValue != 2 || itemValue.value != 7 || ratioValue != 0.0 || labelValue != null) return fail(10);
	if (base.dirty || count.dirty || other.dirty || item.dirty || ratio.dirty || label.dirty || identity.dirty) return fail(11);
	var structuredSignal = new Signal<ValueRecord>(new ValueRecord(4)), structuredValue = 0;
	var structuredReader = new Effect(function() { structuredValue = structuredSignal.value.value; });
	structuredSignal.value = new ValueRecord(4);
	if (structuredReader.dirty || structuredValue != 4) return fail(47);
	structuredSignal.value = new ValueRecord(5);
	if (!structuredReader.dirty) return fail(48);
	ReactiveRuntime.flushEffects();
	if (structuredValue != 5 || structuredReader.dirty) return fail(49);
	structuredReader.dispose();

	model.other = 3;
	if (!other.dirty || base.dirty || count.dirty || item.dirty || ratio.dirty || label.dirty || identity.dirty) return fail(12);
	ReactiveRuntime.flushEffects();
	if (otherValue != 3) return fail(13);
	if (other.dirty) return fail(13);
	model.other = 3;
	if (other.dirty) return fail(14);

	model.item = new EqualValue(7);
	if (item.dirty) return fail(15);
	model.item = new EqualValue(8);
	if (!item.dirty || base.dirty || count.dirty || other.dirty || ratio.dirty || label.dirty || identity.dirty) return fail(16);
	ReactiveRuntime.flushEffects();
	if (itemValue.value != 8) return fail(17);
	if (item.dirty) return fail(17);
	model.valueRecord = new ValueRecord(10);
	if (valueRecord.dirty) return fail(34);
	model.valueRecord = new ValueRecord(11);
	if (!valueRecord.dirty) return fail(35);
	ReactiveRuntime.flushEffects();
	if (valueRecordValue.value != 11 || valueRecord.dirty) return fail(36);
	model.optionalRecord = null;
	if (optionalRecord.dirty) return fail(37);
	model.optionalRecord = new ValueRecord(12);
	if (!optionalRecord.dirty) return fail(38);
	ReactiveRuntime.flushEffects();
	if (optionalRecordValue == null || optionalRecordValue.value != 12 || optionalRecord.dirty) return fail(39);

	model.ratio = -0.0;
	if (ratio.dirty) return fail(18);
	model.ratio = 0.0 / 0.0;
	if (!ratio.dirty || base.dirty || count.dirty || other.dirty || item.dirty || label.dirty || identity.dirty) return fail(19);
	ReactiveRuntime.flushEffects();
	if (ratio.dirty) return fail(20);
	model.ratio = 0.0 / 0.0;
	if (ratio.dirty) return fail(21);
	ReactiveRuntime.flushEffects();
	if (ratio.dirty) return fail(22);

	model.baseValue = 5;
	if (!base.dirty || count.dirty || other.dirty || item.dirty || ratio.dirty || label.dirty || identity.dirty) return fail(23);
	ReactiveRuntime.flushEffects();
	if (labelValue != null || label.dirty) return fail(30);
	if (baseValue != 5) return fail(23);
	model.optionalLabel = null;
	if (label.dirty) return fail(26);
	model.identity = identityValue;
	if (identity.dirty) return fail(31);
	model.identity = new IdentityValue(5);
	if (!identity.dirty || base.dirty || count.dirty || other.dirty || item.dirty || ratio.dirty || label.dirty) return fail(32);
	ReactiveRuntime.flushEffects();
	if (identityValue == null || identityValue != model.identity || identity.dirty) return fail(33);
	model.optionalLabel = "tracked";
	if (!label.dirty || base.dirty || count.dirty || other.dirty || item.dirty || ratio.dirty) return fail(27);
	ReactiveRuntime.flushEffects();
	if (labelValue != "tracked" || label.dirty) return fail(28);
	model.optionalLabel = "tracked";
	if (label.dirty) return fail(29);
	model.optionalLabel = null;
	if (!label.dirty) return fail(30);
	ReactiveRuntime.flushEffects();
	if (labelValue != null || label.dirty) return fail(30);

	var threw = false;
	try {
		new Effect(function() model.count = 9);
	} catch (_:Dynamic) threw = true;
	ReactiveRuntime.flushEffects();
	var constructed:Model = null, constructorWriteThrew = false;
	try {
		ReactiveRuntime.withTracking(count, function() { constructed = new Model(); });
	} catch (_:Dynamic) return fail(25);
	try {
		ReactiveRuntime.withTracking(count, function() { new ConstructorMutation(model); });
	} catch (_:Dynamic) constructorWriteThrew = true;
	var wire = new WireModel();
	var enumModel = new EnumModel(), enumPhase:ObservablePhase = null;
	var enumReader = new Effect(function() { enumPhase = enumModel.phase; });
	enumModel.phase = Idle;
	if (enumReader.dirty) return fail(40);
	var busy = Busy(1);
	enumModel.phase = busy;
	if (!enumReader.dirty) return fail(41);
	ReactiveRuntime.flushEffects();
	if (enumPhase != busy || enumReader.dirty) return fail(42);
	enumModel.phase = busy;
	if (enumReader.dirty) return fail(43);
	enumModel.phase = Busy(1);
	if (enumReader.dirty) return fail(44);
	enumModel.phase = Busy(2);
	if (!enumReader.dirty) return fail(44);
	ReactiveRuntime.flushEffects();
	enumReader.dispose();
	var wireReader = new Effect(function() { var value = wire.label; });
	var encoded = haxeon.wire.JsonWire.encode(wire);
	var decoded:WireModel = haxeon.wire.JsonWire.decode(encoded);
	if (decoded.label != "start" || decoded.note != null ||
		haxeon.wire.JsonWire.encode(decoded) != encoded ||
		encoded.indexOf("haxeonObservableState") >= 0 ||
		Reflect.fields(wire).indexOf("$haxeonObservableState") >= 0 ||
		Reflect.hasField(wire, "$haxeonObservableState")) return fail(34);
	var decodedLabel = "";
	var decodedReader = new Effect(function() { decodedLabel = decoded.label; });
	decoded.label = "changed";
	if (!decodedReader.dirty) return fail(45);
	ReactiveRuntime.flushEffects();
	if (decodedLabel != "changed" || decodedReader.dirty) return fail(46);
	decodedReader.dispose();
	wireReader.dispose();
	Sys.exit(threw && constructorWriteThrew && constructed != null && constructed.baseValue == 4 &&
		constructed.count == 1 && freshEffectValue == 6 && freshDerived.value == 7 &&
		freshSignalEffectValue == 6 && freshSignalDerived.value == 7 &&
		!count.dirty && !other.dirty && !label.dirty ? 42 : 24);
	return 1;
}
