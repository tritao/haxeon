package compiler.hl.lower;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeTools;
import compiler.ir.model.IrValueId;
import compiler.ir.passes.scalars.IrScalarValuePlaces;

typedef HlScalarValueLocal = {
	final fields:Map<String, Int>;
	final declarations:Array<IrObjectField>;
}

/**
 * Frame-owned scalar slots for nonescaping value places (`IrScalarValuePlaces`, here on a body), including across exception
 * handlers. One serves every function lowered: `reset` makes it the places of the next body.
 */
@:nullSafety(Strict)
class HlScalarValueLocals {
	/** Per value id, its local, or null; filled only for a body that has places. */
	final locals:Array<Null<HlScalarValueLocal>> = [];

	/** The value constructions that may be places, with the object each makes, and whether it still qualifies. */
	final rootRows:Array<Int> = [];

	final rootNames:Array<String> = [];
	final rootValid:Array<Bool> = [];

	/** Per value id, its index in `rootRows`, or -1; filled only for a body that has roots. */
	final rootIndices:Array<Int> = [];

	/** `object` of the view last given, made once per view. */
	var lookup:Null<String->Null<IrObject>> = null;

	var lookupView:Null<HlLoweringView> = null;

	public function new() {}

	/** Makes these the places of `body`, each field of each place given a register by `allocate`, in row and field order. */
	public function reset(body:IrBody, objects:HlLoweringView, allocate:IrType->Int):Void {
		release();
		rootRows.resize(0);
		rootNames.resize(0);
		rootValid.resize(0);
		var lookup = this.lookup;
		if (lookup == null || lookupView != objects) {
			lookup = objects.object;
			this.lookup = lookup;
			lookupView = objects;
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ValueInit) {
					var name = IrTypeTools.valueObjectName(body.valueType(body.output(row))),
						object = objects.object(name);
					if (object != null && IrScalarValuePlaces.scalarFields(object, lookup)) {
						rootRows.push(row);
						rootNames.push(name);
						rootValid.push(true);
					}
				}
				row = body.nextRow(row);
			}
		}
		if (rootRows.length == 0)
			return;
		compiler.ir.model.IrPassScratch.filledInts(rootIndices, body.valueLimit(), -1);
		for (index in 0...rootRows.length)
			rootIndices[body.output(rootRows[index])] = index;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (operand in 0...body.operandCount(row)) {
					var input = body.operand(row, operand), root = rootIndices[input];
					if (root >= 0 && !allowed(body, row, input, objects, rootNames[root], operand))
						rootValid[root] = false;
				}
				row = body.nextRow(row);
			}
		}
		for (index in 0...rootRows.length)
			if (rootValid[index]) {
				var out = body.output(rootRows[index]),
					fields:Map<String, Int> = [],
					declaration:IrObject = cast objects.object(IrTypeTools.valueObjectName(body.valueType(out))),
					declarations = declaration.fields;
				for (field in declarations)
					fields.set(field.name, allocate(field.type));
				while (locals.length <= (out:Int))
					locals.push(null);
				locals[out] = {fields: fields, declarations: declarations};
			}
	}

	/**
	 * Whether `row` may read the place `input` as its operand `operand`: as the object of a field it reads, or of a field it
	 * writes another value to. A phi, a call, a return or anything else lets the place escape.
	 */
	static function allowed(body:IrBody, row:Int, input:IrValueId, objects:HlLoweringView, root:String,
			operand:Int):Bool
		return switch body.opcode(row) {
			case IrOpcode.FieldGet: operand == 0 && hasField(objects.object(root), body.symbol(row).name);
			case IrOpcode.FieldSet: operand == 0 && (body.operand(row, 1):Int) != (input:Int)
				&& hasField(objects.object(root), body.symbol(row).name);
			default: false;
		};

	static function hasField(object:Null<IrObject>, name:String):Bool {
		if (object != null)
			for (field in object.fields)
				if (field.name == name)
					return true;
		return false;
	}

	public function get(value:IrValueId):Null<HlScalarValueLocal>
		return (value:Int) < locals.length ? locals[value] : null;

	/** Drops the locals of the body last reset. */
	public function release():Void {
		for (index in 0...locals.length)
			locals[index] = null;
		locals.resize(0);
	}
}
