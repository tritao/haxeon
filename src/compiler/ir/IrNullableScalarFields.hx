package compiler.ir;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.Ir;

/**
 * Preserve the payload width of a nullable native scalar on every field store. On IR bodies (docs/design/IR_CORE_COLUMNS.md,
 * migration): a store is preceded in place by a call of the width's normalizer, whose functions are built and encoded later.
 */
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
		var rewritten:Array<IrFunction> = [];
		for (fn in functions) {
			var body = fn.bodyIn(types, builder);
			if (!needsRewrite(body)) {
				rewritten.push(fn);
				continue;
			}
			var edited = body.forEditing(builder);
			rewriteBody(edited);
			rewritten.push(IrFunction.ofOwnedBody(edited));
		}
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

	/** The field a store row of `body` writes, when it has a nullable scalar storage. */
	function narrowedField(body:IrBody, row:Int):Null<IrObjectField> {
		if (body.opcode(row) != IrOpcode.FieldSet)
			return null;
		var field = findField(body.valueType(body.operand(row, 0)), body.symbol(row).name);
		return field != null && field.nullableScalarStorage != null ? field : null;
	}

	function rewriteBody(body:IrBody):Void {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var field = narrowedField(body, row);
				if (field != null) {
					var helper = helperFor(field.type, field.nullableScalarStorage),
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

	function needsRewrite(body:IrBody):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (narrowedField(body, row) != null)
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	function helperFor(type:IrType, storage:IrScalarStorage):String {
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
		var objectName = switch type {
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
