package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Preserve the payload width of a nullable native scalar on every field store. */
class IrNullableScalarFields {
	final objects:Map<String, IrObject>;
	final helpers:Map<String, IrFunction> = [];

	public function new(declarations:Array<IrObject>)
		objects = [for (object in declarations) object.name => object];

	public function rewrite(functions:Array<IrFunction>):Array<IrFunction> {
		var rewritten = [for (fn in functions) rewriteFunction(fn)];
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var helper = helpers.get(name);
			if (helper == null)
				throw 'Missing nullable scalar helper "$name"';
			rewritten.push(helper);
		}
		return rewritten;
	}

	function rewriteFunction(fn:IrFunction):IrFunction {
		if (!needsRewrite(fn))
			return fn;
		var next = nextValue(fn), changed = false, blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value, rewrittenInstruction = false;
				switch instruction {
					case FieldSet(owner, name, value):
						var field = findField(owner.type, name);
						if (field != null && field.nullableScalarStorage != null) {
							var helper = helperFor(field.type, field.nullableScalarStorage);
							var normalized = new IrValue(next++, "$nullable-scalar", field.type);
							copy.instructions.push(new Located(Call(normalized, helper, [value]), located.provenance));
							instruction = FieldSet(owner, name, normalized);
							rewrittenInstruction = true;
							changed = true;
						}
					default:
				}
				copy.instructions.push(rewrittenInstruction ? new Located(instruction, located.provenance) : located);
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return changed ? fn.withBlocks(blocks) : fn;
	}

	function needsRewrite(fn:IrFunction):Bool {
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case FieldSet(owner, name, _):
						var field = findField(owner.type, name);
						if (field != null && field.nullableScalarStorage != null)
							return true;
					default:
				}
		return false;
	}

	function helperFor(type:IrType, storage:IrScalarStorage):String {
		var element = switch type {
			case Nullable(I32): I32;
			case Nullable(I64): I64;
			default: throw 'Invalid nullable scalar field type $type';
		};
		var bits = (switch (element) {
			case I64: true;
			default: false;
		}) ? 64 : 32, width = storage.size * 8;
		if (width <= 0 || width >= bits)
			throw 'Invalid nullable scalar width $width for $type';
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
			normalized = storage.signed ? builder.shiftRight(shifted, shift) : builder.unsignedShiftRight(shifted, shift);
		builder.branch(builder.equal(raw, normalized), same, changed);
		builder.select(same);
		builder.returnValue(value);
		builder.select(changed);
		builder.returnValue(builder.toDyn(normalized, type));
		helpers.set(name, new IrFunction(name, builder.arguments, type, builder.blocks, GeneratedHelper));
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

	static function nextValue(fn:IrFunction):Int {
		var next = 0;
		for (argument in fn.arguments)
			if (argument.id >= next)
				next = argument.id + 1;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= next)
					next = output.id + 1;
				for (input in IrOperands.inputs(located.value))
					if (input.id >= next)
						next = input.id + 1;
			}
		return next;
	}
}
