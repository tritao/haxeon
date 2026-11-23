package compiler.ir.passes.values;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.reuse.IrFactReader;

/**
 * A rewrite of the functions that have a row of one opcode whose output is a value object (`IrObject.isValue`), per function
 * (`IrFunctionPass`): scalar replacement's value allocations, value phi scalarization's value phis. A function's summary says
 * whether it has such a row with an object output at all; its rewrite reads, for each such object, whether it is a value class
 * (`VALUE`), so a function with none keeps its form unread while those facts hold. One with a value row also reads what the
 * rewrite reads of the declarations, the value objects' layouts, as one fact (`REWRITE`, `IrInlineValueLayout.declarationsFact`).
 */
@:nullSafety(Strict)
class IrValueObjectRows implements IrFunctionPass {
	static inline final VALUE = 0;
	static inline final REWRITE = 1;

	/** The summary of a function with a row of the opcode whose output is an object. */
	static inline final OBJECT_ROWS = 1;

	final opcode:IrOpcode;
	final objects:IrObjectTable;
	final types:IrTypeIds;
	final builder:IrBodyBuilder;
	final rewrite:IrFunction->IrFunction;
	final declarations:() -> Int;

	public function new(opcode:IrOpcode, objects:IrObjectTable, types:IrTypeIds, builder:IrBodyBuilder,
			rewrite:IrFunction->IrFunction, declarations:() -> Int) {
		this.declarations = declarations;
		this.opcode = opcode;
		this.objects = objects;
		this.types = types;
		this.builder = builder;
		this.rewrite = rewrite;
	}

	static function objectName(type:IrType):Null<String>
		return switch type {
			case Obj(name): name;
			default: null;
		};

	public function summarize(fn:IrFunction):Int {
		var body = fn.bodyIn(types, builder);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == opcode && objectName(body.valueType(body.output(row))) != null)
					return OBJECT_ROWS;
				row = body.nextRow(row);
			}
		}
		return 0;
	}

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {}

	public function fact(kind:Int, key:String):Int
		return switch kind {
			case VALUE:
				var object = objects.get(key);
				object != null && object.isValue ? 1 : 0;
			default: declarations();
		};

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (summary != OBJECT_ROWS)
			return fn;
		if (reader.records()) {
			var body = fn.bodyIn(types, builder), found = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0 && !found) {
					if (body.opcode(row) == opcode) {
						var name = objectName(body.valueType(body.output(row)));
						if (name != null && reader.read(VALUE, name) == 1)
							found = true;
					}
					row = body.nextRow(row);
				}
				if (found)
					break;
			}
			if (!found)
				return fn;
			reader.read(REWRITE, "");
		}
		return rewrite(fn);
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		throw new InternalError("A value object rows rewrite asks for no helper");

	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;
}
