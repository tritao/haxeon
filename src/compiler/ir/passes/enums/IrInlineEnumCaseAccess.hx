package compiler.ir.passes.enums;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrObjectTable;
import compiler.ir.passes.enums.IrInlineEnumLayout.IrInlineEnumCaseShape;
import compiler.ir.passes.enums.IrInlineEnumLayout.IrInlineEnumShape;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneSlot;
import compiler.ir.passes.values.IrValueLaneReference;
import compiler.ir.verify.IrVerifier;

/** Construct and project one case through its overlapping scalar and reference lanes. */
class IrInlineEnumCaseAccess {
	public static inline final HELPER_PREFIX = "$inline-enum:helper:";

	final shape:IrInlineEnumShape;
	final objects:IrObjectTable;
	final words:IrInlineEnumWordAccess;

	public function new(shape:IrInlineEnumShape, objects:IrObjectTable) {
		this.shape = shape;
		this.objects = objects;
		words = new IrInlineEnumWordAccess(shape.wordBits);
	}

	/** Arguments have already been evaluated in source order. */
	public function construct(builder:IrBuilder, constructor:Int, arguments:Array<IrValue>):IrValue {
		var entry = getCase(constructor);
		if (arguments.length != entry.parameters.length)
			throw new InternalError("Wrong inline enum constructor arity");
		var result = nullValue(builder);
		builder.fieldSet(result, "tag", builder.constInt(constructor + 1));
		for (index in 0...arguments.length) {
			if (!IrVerifier.sameType(arguments[index].type, entry.parameters[index]))
				throw new InternalError("Wrong inline enum payload type");
			write(builder, result, entry, [Std.string(index)], arguments[index]);
		}
		return result;
	}

	/** Tag zero is the null value and contains no live payload. */
	public function nullValue(builder:IrBuilder):IrValue {
		var result = builder.valueInit(shape.valueObject.name);
		builder.fieldSet(result, "tag", builder.constInt(0));
		for (index in 0...shape.scalarWords)
			builder.fieldSet(result, 'scalar$index', builder.constInt(0, shape.wordBits == 64 ? I64 : I32));
		for (index in 0...shape.references)
			builder.fieldSet(result, 'reference$index', builder.constNull(IrValueLaneReference.type()));
		return result;
	}

	/** Caller has already checked the active case before extracting a payload. */
	public function field(builder:IrBuilder, value:IrValue, constructor:Int, index:Int):IrValue {
		var entry = getCase(constructor);
		if (index < 0 || index >= entry.parameters.length)
			throw new InternalError("Invalid inline enum payload index");
		return read(builder, value, entry, [Std.string(index)], entry.parameters[index]);
	}

	/** Separate optional scalar components avoid a nullable box across a typed projection. */
	public function scalarPresence(builder:IrBuilder, value:IrValue, constructor:Int, index:Int):IrValue {
		var entry = getCase(constructor);
		return words.read(builder, value, slot(entry, [Std.string(index)], true, false));
	}

	public function scalarPayload(builder:IrBuilder, value:IrValue, constructor:Int, index:Int):IrValue {
		var entry = getCase(constructor);
		return readLeaf(builder, value, slot(entry, [Std.string(index)], false, true));
	}

	function write(builder:IrBuilder, target:IrValue, entry:IrInlineEnumCaseShape, path:Array<String>,
			value:IrValue):Void {
		switch value.type {
			case Nullable(inner) if (isValue(inner) || primitive(inner)):
				var absent = builder.createBlock(),
					present = builder.createBlock(),
					done = builder.createBlock();
				var nil = builder.equal(value, builder.constNull(value.type));
				builder.branch(nil, absent, present);
				builder.select(absent);
				words.write(builder, target, slot(entry, path, true, false), builder.constBool(false));
				builder.jump(done);
				builder.select(present);
				words.write(builder, target, slot(entry, path, true, false), builder.constBool(true));
				var unwrapped = builder.safeCast(value, inner);
				if (primitive(inner))
					writeLeaf(builder, target, slot(entry, path, false, true), unwrapped);
				else
					write(builder, target, entry, path, unwrapped);
				builder.jump(done);
				builder.select(done);
			case Obj(name) if (isValue(value.type)):
				var object = requireObject(name);
				for (field in object.fields)
					write(builder, target, entry, path.concat([field.name]),
						builder.fieldGet(value, field.name, field.type));
			default:
				writeLeaf(builder, target, slot(entry, path, false, false), value);
		}
	}

	function read(builder:IrBuilder, source:IrValue, entry:IrInlineEnumCaseShape, path:Array<String>,
			type:IrType):IrValue {
		return switch type {
			case Nullable(inner) if (isValue(inner) || primitive(inner)):
				var flag = words.read(builder, source, slot(entry, path, true, false));
				var present = builder.createBlock(),
					absent = builder.createBlock(),
					done = builder.createBlock();
				builder.branch(flag, present, absent);
				builder.select(absent);
				var nil = builder.constNull(type),
					absentBlock = builder.currentBlock();
				builder.jump(done);
				builder.select(present);
				var payload = primitive(inner) ? readLeaf(builder, source,
					slot(entry, path, false, true)) : read(builder, source, entry, path, inner);
				var wrapped = builder.toDyn(payload, type),
					presentBlock = builder.currentBlock();
				builder.jump(done);
				builder.select(done);
				builder.phi(type, [{block: absentBlock.id, value: nil}, {block: presentBlock.id, value: wrapped}]);
			case Obj(name) if (isValue(type)):
				var result = builder.valueInit(name);
				for (field in requireObject(name).fields)
					builder.fieldSet(result, field.name,
						read(builder, source, entry, path.concat([field.name]), field.type));
				result;
			default: readLeaf(builder, source, slot(entry, path, false, false));
		};
	}

	function writeLeaf(builder:IrBuilder, target:IrValue, leaf:IrValueLaneSlot, value:IrValue):Void {
		if (leaf.isReference)
			IrInlineEnumReferenceAccess.write(builder, target, leaf.index, value);
		else
			words.write(builder, target, leaf, value);
	}

	function readLeaf(builder:IrBuilder, source:IrValue, leaf:IrValueLaneSlot):IrValue
		return leaf.isReference ? IrInlineEnumReferenceAccess.read(builder, source, leaf.index,
			leaf.type) : words.read(builder, source, leaf);

	function getCase(index:Int):IrInlineEnumCaseShape {
		if (index < 0 || index >= shape.cases.length)
			throw new InternalError("Invalid inline enum case");
		return shape.cases[index];
	}

	static function slot(entry:IrInlineEnumCaseShape, path:Array<String>, presence:Bool,
			nullablePayload:Bool):IrValueLaneSlot {
		for (candidate in entry.payload.slots) {
			if (candidate.isPresence != presence || candidate.nullablePayload != nullablePayload
				|| candidate.path.length != path.length)
				continue;
			var same = true;
			for (index in 0...path.length)
				if (candidate.path[index] != path[index]) {
					same = false;
					break;
				}
			if (same)
				return candidate;
		}
		throw new InternalError('Missing inline enum payload slot ${path.join(".")}');
	}

	function isValue(type:IrType):Bool
		return switch type {
			case Obj(name): var object = objects.get(name);
				object != null && object.isValue;
			default: false;
		};

	function requireObject(name:String):IrObject {
		var object = objects.get(name);
		if (object == null || !object.isValue)
			throw new InternalError('Missing inline enum payload value "$name"');
		return object;
	}

	static function primitive(type:IrType):Bool
		return switch type {
			case I32, I64, F32, F64, Bool: true;
			default: false;
		};
}

/** Traced enum payload slots carry references without materializing Dynamic boxes. */
class IrInlineEnumReferenceAccess {
	public static function write(builder:IrBuilder, owner:IrValue, index:Int, value:IrValue):Void {
		if (IrValueLaneReference.isCarrier(value.type)) {
			builder.fieldSet(owner, 'reference$index', value);
			return;
		}
		if (!IrValueLaneReference.canCarry(value.type))
			throw new InternalError('Cannot store ${value.type} in an enum reference slot');
		var carrier = builder.call(IrValueLaneReference.PACK, [value], IrValueLaneReference.type());
		builder.fieldSet(owner, 'reference$index', carrier);
	}

	public static function read(builder:IrBuilder, owner:IrValue, index:Int, type:IrType):IrValue {
		if (IrValueLaneReference.isCarrier(type)) return builder.fieldGet(owner, 'reference$index', type);
		if (!IrValueLaneReference.canCarry(type))
			throw new InternalError('Cannot load $type from an enum reference slot');
		var carrier = builder.fieldGet(owner, 'reference$index', IrValueLaneReference.type());
		return builder.call(IrValueLaneReference.UNPACK, [carrier], type);
	}
}
