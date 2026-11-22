package compiler.ir.passes.nullability;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.TypeKey;

/**
 * Preserve the payload width of a nullable native scalar on every field store. On IR bodies (docs/design/IR_CORE_COLUMNS.md,
 * migration): a store is preceded in place by a call of the width's normalizer, whose functions are built and encoded later.
 */
@:nullSafety(Strict)
class IrNullableScalarFields {
	final objects:Map<String, IrObject>;
	final helpers:Map<String, IrFunction> = [];

	public function new(declarations:Array<IrObject>)
		objects = [for (object in declarations) object.name => object];

	/**
	 * `functions` with their stores normalized, read as their bodies made with `types` (those of the functions' bodies when not
	 * given): a function that changes becomes its edited body, owned by the next stage; the normalizers come last.
	 */
	public function rewrite(functions:Array<IrFunction>, ?types:IrTypeIds, ?builder:IrBodyBuilder):Array<IrFunction> {
		if (types == null)
			types = IrTypeIds.ofFunctions(functions);
		return compiler.ir.pipeline.IrFunctionStages.apply("nullable-scalar-fields",
			new IrNullableScalarFieldsPass(this, types, builder), functions);
	}

	/** The rewritten functions with the normalizers made, which come last. */
	public function withHelpers(rewritten:Array<IrFunction>):Array<IrFunction> {
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var helper = helpers.get(name);
			if (helper == null)
				throw new InternalError('Missing nullable scalar helper "$name"');
			rewritten.push(helper);
		}
		return rewritten;
	}

	/**
	 * The field a store row of `body` writes, when it has a nullable scalar storage: read through `reader`'s fact of the field
	 * (`IrNullableScalarFieldsPass`) when given.
	 */
	public function narrowedField(body:IrBody, row:Int, ?reader:compiler.ir.reuse.IrFactReader):Null<IrObjectField> {
		if (body.opcode(row) != IrOpcode.FieldSet)
			return null;
		var type = body.valueType(body.operand(row, 0)), name = body.symbol(row).name;
		if (reader != null)
			switch type {
				case Obj(object):
					reader.read(IrNullableScalarFieldsPass.FIELD, object + "\u0001" + name);
				default:
			}
		var field = findField(type, name);
		return field != null && field.nullableScalarStorage != null ? field : null;
	}

	/** The fact of a store into `name` of an object of class `object`: 0 when it keeps no nullable scalar, else its storage. */
	public function storageCode(object:String, name:String):Int {
		var field = findField(Obj(object), name), storage = field == null ? null : field.nullableScalarStorage;
		if (field == null || storage == null)
			return 0;
		var wide = switch field.type {
			case Nullable(I64): 2;
			default: 0;
		};
		return 1 + wide + (storage.signed ? 4 : 0) + storage.size * 8;
	}

	public function rewriteBody(body:IrBody, ?reader:compiler.ir.reuse.IrFactReader):Void {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var field = narrowedField(body, row, reader);
				var storage = field == null ? null : field.nullableScalarStorage;
				if (field != null && storage != null) {
					if (reader != null)
						reader.request(storage.size * 2 + (storage.signed ? 1 : 0), field.type);
					var helper = helperFor(field.type, storage),
						normalized = body.newValue("$nullable-scalar", body.typeId(field.type));
					body.beginRow();
					body.pushOperand(body.operand(row, 1));
					body.linkBefore(block, row,
						body.endRow(IrOpcode.Call, normalized, IrSymbol.of(helper).id, body.provenance(row)));
					body.setOperand(row, 1, normalized);
				}
				row = body.nextRow(row);
			}
		}
	}

	public function needsRewrite(body:IrBody, ?reader:compiler.ir.reuse.IrFactReader):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (narrowedField(body, row, reader) != null)
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	public function helperFor(type:IrType, storage:IrScalarStorage):String {
		var element = switch type {
			case Nullable(I32): I32;
			case Nullable(I64): I64;
			default: throw new InternalError('Invalid nullable scalar field type $type');
		};
		var bits = (switch (element) {
			case I64: true;
			default: false;
		}) ? 64 : 32, width = storage.size * 8;
		if (width <= 0 || width >= bits)
			throw new InternalError('Invalid nullable scalar width $width for $type');
		var name = '$' + 'nullable-scalar-normalize:' + bits + ':' + width + ':' + storage.signed;
		if (helpers.exists(name))
			return name;
		var builder = new IrBuilder(), value = builder.argument("value", type);
		var absent = builder.createBlock(),
			present = builder.createBlock(),
			same = builder.createBlock(),
			changed = builder.createBlock();
		builder.branch(builder.equal(value, builder.constNull(type)), absent, present);
		builder.select(absent);
		builder.returnValue(value);
		builder.select(present);
		var raw = builder.safeCast(value, element),
			shift = builder.constInt(bits - width),
			shifted = builder.shiftLeft(raw, shift),
			normalized = storage.signed ? builder.shiftRight(shifted, shift) : builder.unsignedShiftRight(shifted,
				shift);
		builder.branch(builder.equal(raw, normalized), same, changed);
		builder.select(same);
		builder.returnValue(value);
		builder.select(changed);
		builder.returnValue(builder.toDyn(normalized, type));
		helpers.set(name,
			new IrFunction(name, builder.arguments, type, builder.blocks,
			Provider(TypeKey.of(type), ProviderOperations.detailed(ProviderOperation.NullableScalarHelper, name))));
		return name;
	}

	function findField(type:IrType, name:String):Null<IrObjectField> {
		var objectName:Null<String> = switch type {
			case Obj(value): value;
			default: return null;
		};
		while (objectName != null) {
			var object = objects.get(objectName);
			if (object == null)
				return null;
			for (field in object.fields)
				if (field.name == name)
					return field;
			objectName = object.base;
		}
		return null;
	}

}

/**
 * `IrNullableScalarFields.rewrite` per function (`IrFunctionPass`) on bodies: a function's summary says whether it stores a
 * nullable Int at all; the rewrite reads, for each field it stores to, the field's nullable scalar storage (`FIELD`), and asks for
 * the normalizer of each width it stores.
 */
@:nullSafety(Strict)
class IrNullableScalarFieldsPass implements compiler.ir.pipeline.IrFunctionPass {
	public static inline final FIELD = 0;

	static inline final STORES = 1;

	final fields:IrNullableScalarFields;
	final types:IrTypeIds;
	final builder:Null<IrBodyBuilder>;

	public function new(fields:IrNullableScalarFields, types:IrTypeIds, ?builder:IrBodyBuilder) {
		this.fields = fields;
		this.types = types;
		this.builder = builder;
	}

	public function summarize(fn:IrFunction):Int {
		var body = fn.bodyIn(types, builder);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.FieldSet)
					switch body.valueType(body.operand(row, 1)) {
						case Nullable(I32 | I64):
							return STORES;
						default:
					}
				row = body.nextRow(row);
			}
		}
		return 0;
	}

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>,
			names:compiler.ir.pipeline.IrFunctionIndex):Void {}

	public function fact(kind:Int, key:String):Int {
		var split = key.indexOf("\u0001");
		return fields.storageCode(key.substr(0, split), key.substr(split + 1));
	}

	public function transform(fn:IrFunction, summary:Int, reader:compiler.ir.reuse.IrFactReader):IrFunction {
		if (summary != STORES)
			return fn;
		var body = fn.bodyIn(types, builder), recording = reader.records() ? reader : null;
		if (!fields.needsRewrite(body, recording))
			return fn;
		var edited = body.forEditing(builder);
		fields.rewriteBody(edited, recording);
		return IrFunction.ofOwnedBody(edited);
	}

	public function request(kind:Int, type:IrType):Void
		fields.helperFor(type, {size: kind >> 1, signed: kind & 1 == 1});

	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return fields.withHelpers(functions);
}
