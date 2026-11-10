package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.codec.IrTypeCodec;

private typedef IrValueArraySnapshot = {final slot:Int; final value:IrValue; final ?active:IrValue;}

/** Dynamic escapes materialize a value; ordinary typed lane access never calls these helpers. */
class IrValueArrayBridge {
	public final storage:IrType;
	final element:IrType;
	final objects:IrObjectTable;
	final helpers:IrValueArraySlotHelpers;
	final name:String;

	public function new(element:IrType, storage:IrType, objects:IrObjectTable, helpers:IrValueArraySlotHelpers) {
		this.element = element;
		this.storage = storage;
		this.objects = objects;
		this.helpers = helpers;
		this.name = "$value-array:bridge:" + haxe.crypto.Base64.encode(IrTypeCodec.encode(element));
	}

	public function readName():String return name + ":read";
	public function writeName():String return name + ":write";
	public function acceptsName():String return name + ":accepts";

	public function functions():Array<IrFunction> {
		var arrayType:IrType = Array(element), read = new IrBuilder(), readArray = read.argument("array", arrayType),
			readIndex = read.argument("index", I32);
		var loaded = readValue(read, readArray, readIndex, storage, []);
		read.returnValue(switch valueType(element) {
			case EnumTag(name): read.call(IrEnumTagStorage.boxName(name), [loaded], Dyn);
			case Enum(name): read.call(IrInlineEnumEscapes.boxName(name), [loaded], Dyn);
			default: read.toDyn(loaded);
		});
		var write = new IrBuilder(), writeArray = write.argument("array", arrayType), writeIndex = write.argument("index", I32),
			input = write.argument("value", Dyn), inserting = write.argument("insert", Bool);
		var converted = switch valueType(element) {
			case EnumTag(name): write.call(IrEnumTagStorage.unboxName(name), [input], storage);
			case Enum(name): write.call(IrInlineEnumEscapes.unboxName(name), [input], storage);
			default: write.safeCast(input, element);
		};
		var leaves = snapshot(write, converted, storage, []), references = write.constBool(false);
		for (leaf in leaves) if (helpers.subtree([])[leaf.slot].slot.isReference) {
			// Unpacking a carrier is a pointer move, not a Dynamic conversion. Only inspect nullness here.
			var reference = IrValueLaneReference.isCarrier(leaf.value.type)
				? write.call(IrValueLaneReference.UNPACK, [leaf.value], Dyn) : leaf.value;
			var empty = write.createBlock(), present = write.createBlock(), join = write.createBlock();
			write.branch(write.equal(reference, write.constNull(reference.type)), empty, present);
			write.select(empty); var no = write.currentBlock().id; write.jump(join);
			write.select(present); var yesValue = write.constBool(true), yes = write.currentBlock().id; write.jump(join);
			write.select(join); references = write.phi(Bool, [{block: no, value: references}, {block: yes, value: yesValue}]);
		}
		var position = write.call("__value_array_prepare_write", [writeArray, writeIndex, inserting, references], I32);
		for (leaf in leaves) {
			if (leaf.active == null) write.call(helpers.setter(leaf.slot), [writeArray, position, leaf.value], Void);
			else {
				var live = write.createBlock(), next = write.createBlock();
				write.branch(leaf.active, live, next); write.select(live);
				write.call(helpers.setter(leaf.slot), [writeArray, position, leaf.value], Void);
				write.jump(next); write.select(next);
			}
		}
		write.call("__value_array_mark", [writeArray, position], Void);
		write.returnValue(write.constVoid());
		var accepts = new IrBuilder(), value = accepts.argument("value", Dyn), logical = switch valueType(element) { case EnumTag(name): Enum(name); default: valueType(element); },
			type = accepts.typeValue(logical);
		var matches = accepts.call("__std_is_exact_type", [value, type], Bool);
		if (isOptional(element) || switch element { case Enum(_), EnumTag(_): true; default: false; }) {
			var nil = accepts.equal(value, accepts.constNull(Dyn)), absent = accepts.createBlock(), present = accepts.createBlock();
			accepts.branch(nil, absent, present);
			accepts.select(absent); accepts.returnValue(accepts.constBool(true));
			accepts.select(present);
		}
		accepts.returnValue(matches);
		return [new IrFunction(readName(), read.arguments, Dyn, read.blocks, GeneratedHelper),
			new IrFunction(writeName(), write.arguments, Void, write.blocks, GeneratedHelper),
			new IrFunction(acceptsName(), accepts.arguments, Bool, accepts.blocks, GeneratedHelper)];
	}

	/** Snapshot every leaf before capacity allocation or an insertion can change any array place. */
	function snapshot(b:IrBuilder, value:IrValue, type:IrType, path:Array<String>):Array<IrValueArraySnapshot> {
		return switch type {
			case Nullable(inner) if (isValue(inner) || isScalar(inner)):
				var absent = b.createBlock(), present = b.createBlock(), done = b.createBlock();
				b.branch(b.equal(value, b.constNull(type)), absent, present);
				b.select(absent);
				var presence = helpers.slot(path, true), empty = [for (leaf in helpers.subtree(path))
					{slot: leaf.index, value: zero(b, leaf.slot.type), active: b.constBool(leaf.index == presence)}], absentEnd = b.currentBlock().id;
				b.jump(done); b.select(present);
				var unwrapped = b.safeCast(value, inner), live:Array<IrValueArraySnapshot> = [{slot: presence, value: b.constBool(true)}];
				if (isScalar(inner)) live.push({slot: helpers.slot(path, false, true), value: unwrapped});
				else live = live.concat(snapshot(b, unwrapped, inner, path));
				var active = [for (leaf in live) {slot: leaf.slot, value: leaf.active == null ? b.constBool(true) : leaf.active}],
					presentEnd = b.currentBlock().id; b.jump(done); b.select(done);
				[for (leaf in empty) {
					var actual = [for (item in live) if (item.slot == leaf.slot) item.value],
						actualActive = [for (item in active) if (item.slot == leaf.slot) item.value];
					if (actual.length != 1) throw "Incomplete dynamic value-array snapshot";
					{slot: leaf.slot, value: b.phi(leaf.value.type, [{block: absentEnd, value: leaf.value}, {block: presentEnd, value: actual[0]}]),
						active: b.phi(Bool, [{block: absentEnd, value: leaf.active}, {block: presentEnd, value: actualActive[0]}])};
				}];
			case Obj(name) if (isValue(type)):
				var leaves:Array<IrValueArraySnapshot> = [];
				for (field in requireObject(name).fields)
					leaves = leaves.concat(snapshot(b, b.fieldGet(value, field.name, field.type), field.type, path.concat([field.name])));
				leaves;
			default: [{slot: helpers.slot(path), value: value}];
		};
	}

	static function zero(b:IrBuilder, type:IrType):IrValue return switch type {
		case Bool: b.constBool(false);
		case I32, I64: b.constInt(0, type);
		case F32, F64: b.constFloat(0, type);
		// Type handles have no typed null. This valid SSA placeholder is never stored for an inactive leaf:
		// its absent ancestor's presence setter clears the payload bytes instead.
		case TypeRef: b.typeValue(Dyn);
		default: b.constNull(type);
	};

	public function readValue(builder:IrBuilder, array:IrValue, index:IrValue, type:IrType, path:Array<String>):IrValue {
		return switch type {
			case Nullable(inner) if (isValue(inner) || isScalar(inner)):
				var flag = builder.call(helpers.getter(helpers.slot(path, true)), [array, index], Bool),
					present = builder.createBlock(), absent = builder.createBlock(), done = builder.createBlock();
				builder.branch(flag, present, absent);
				builder.select(absent); var nil = builder.constNull(type), absentBlock = builder.currentBlock(); builder.jump(done);
				builder.select(present);
				var payload = isScalar(inner) ? builder.call(helpers.getter(helpers.slot(path, false, true)), [array, index], inner)
					: readValue(builder, array, index, inner, path);
				var boxed = builder.toDyn(payload, type), presentBlock = builder.currentBlock(); builder.jump(done);
				builder.select(done); builder.phi(type, [{block: absentBlock.id, value: nil}, {block: presentBlock.id, value: boxed}]);
			case Obj(className) if (isValue(type)):
				var result = builder.newObject(className), object = requireObject(className);
				for (field in object.fields) builder.fieldSet(result, field.name, readValue(builder, array, index, field.type, path.concat([field.name])));
				result;
			default: builder.call(helpers.getter(helpers.slot(path)), [array, index], type);
		};
	}

	public function writeValue(builder:IrBuilder, array:IrValue, index:IrValue, value:IrValue, type:IrType, path:Array<String>):Void {
		switch type {
			case Nullable(inner) if (isValue(inner) || isScalar(inner)):
				var absent = builder.createBlock(), present = builder.createBlock(), done = builder.createBlock();
				builder.branch(builder.equal(value, builder.constNull(type)), absent, present);
				builder.select(absent);
				builder.call(helpers.setter(helpers.slot(path, true)), [array, index, builder.constBool(false)], Void);
				builder.jump(done);
				builder.select(present);
				var unwrapped = builder.safeCast(value, inner);
				builder.call(helpers.setter(helpers.slot(path, true)), [array, index, builder.constBool(true)], Void);
				if (isScalar(inner)) builder.call(helpers.setter(helpers.slot(path, false, true)), [array, index, unwrapped], Void);
				else writeValue(builder, array, index, unwrapped, inner, path);
				builder.jump(done); builder.select(done);
			case Obj(className) if (isValue(type)):
				for (field in requireObject(className).fields)
					writeValue(builder, array, index, builder.fieldGet(value, field.name, field.type), field.type, path.concat([field.name]));
			default: builder.call(helpers.setter(helpers.slot(path)), [array, index, value], Void);
		}
	}

	function isValue(type:IrType):Bool return switch type {
		case Obj(name): var object = objects.get(name); object != null && object.isValue;
		default: false;
	};
	function requireObject(name:String):IrObject {
		var object = objects.get(name);
		if (object == null) throw 'Missing value array object "$name"';
		return object;
	}
	static function isScalar(type:IrType):Bool return switch type { case I32, I64, F32, F64, Bool: true; default: false; };
	static function isOptional(type:IrType):Bool return switch type { case Nullable(_): true; default: false; };
	static function valueType(type:IrType):IrType return switch type { case Nullable(inner): inner; default: type; };
}
