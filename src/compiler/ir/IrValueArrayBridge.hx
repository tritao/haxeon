package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.codec.IrTypeCodec;

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
			case Enum(name): read.call(IrInlineEnumEscapes.boxName(name), [loaded], Dyn);
			default: read.toDyn(loaded);
		});
		var write = new IrBuilder(), writeArray = write.argument("array", arrayType), writeIndex = write.argument("index", I32),
			input = write.argument("value", Dyn);
		write.call("__value_array_ensure", [writeArray, writeIndex], Void);
		var converted = switch valueType(element) {
			case Enum(name): write.call(IrInlineEnumEscapes.unboxName(name), [input], storage);
			default: write.safeCast(input, element);
		};
		writeValue(write, writeArray, writeIndex, converted, storage, []);
		write.call("__value_array_mark", [writeArray, writeIndex], Void);
		write.returnValue(write.constVoid());
		var accepts = new IrBuilder(), value = accepts.argument("value", Dyn), type = accepts.typeValue(valueType(element));
		var matches = accepts.call("__std_is_exact_type", [value, type], Bool);
		if (isOptional(element) || switch element { case Enum(_): true; default: false; }) {
			var nil = accepts.equal(value, accepts.constNull(Dyn)), absent = accepts.createBlock(), present = accepts.createBlock();
			accepts.branch(nil, absent, present);
			accepts.select(absent); accepts.returnValue(accepts.constBool(true));
			accepts.select(present);
		}
		accepts.returnValue(matches);
		return [new IrFunction(readName(), read.arguments, Dyn, read.blocks),
			new IrFunction(writeName(), write.arguments, Void, write.blocks),
			new IrFunction(acceptsName(), accepts.arguments, Bool, accepts.blocks)];
	}

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
