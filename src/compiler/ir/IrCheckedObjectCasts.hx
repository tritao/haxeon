package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Check Dynamic-to-object casts before target-specific casts, so failure remains catchable. */
class IrCheckedObjectCasts {
	public static inline final PREFIX = "$checked-object-cast:";
	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, checkObjects:Bool, ?existingFunctions:Array<IrFunction>,
			checkValueObjects:Bool = false):Array<IrFunction> {
		var declarations:Map<String, IrObject> = [for (object in objects) object.name => object],
			helpers:Map<String, String> = [], generated:Array<IrFunction> = [],
			known:Map<String, Bool> = [for (fn in (existingFunctions == null ? functions : existingFunctions.concat(functions))) fn.name => true];
		function helperFor(type:IrType, checkedType:IrType, typeName:String, allowNull:Bool):String {
			var key = Std.string(type), existing = helpers.get(key);
			if (existing != null) return existing;
			var name = PREFIX + key, builder = new IrBuilder(), input = builder.argument("value", Dyn),
				check = builder.createBlock(), accepted = builder.createBlock(), rejected = builder.createBlock();
			helpers.set(key, name);
			if (known.exists(name)) return name;
			if (!allowNull) builder.jump(check);
			else builder.branch(builder.equal(input, builder.constNull(Dyn)), accepted, check);
			builder.select(check);
			builder.branch(builder.call("__std_is_of_type", [input, builder.typeValue(checkedType)], Bool), accepted, rejected);
			builder.select(accepted);
			builder.returnValue(builder.safeCast(input, type));
			builder.select(rejected);
			builder.terminate(Throw(builder.toDyn(builder.constString('Invalid cast to $typeName'))));
			generated.push(new IrFunction(name, builder.arguments, type, builder.blocks));
			return name;
		}
		var rewritten:Array<IrFunction> = [];
		for (fn in functions) {
			var changed = false, blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var target = new IrBlock(block.id);
				for (located in block.instructions) switch located.value {
					case SafeCast(out, input) if ((switch (input.type) { case Dyn: true; default: false; })):
						switch out.type {
							case Obj(name) if (declarations.exists(name) && (checkObjects || (checkValueObjects && declarations.get(name).isValue))):
								var declaration = declarations.get(name);
								if (declaration == null) throw 'Missing cast target "$name"';
								target.instructions.push(new Located(Call(out, helperFor(out.type, out.type, name, !declaration.isValue), [input]), located.provenance));
								changed = true;
							case Nullable(Obj(name)) if (checkValueObjects && declarations.exists(name) && declarations.get(name).isValue):
								target.instructions.push(new Located(Call(out, helperFor(out.type, Obj(name), name, true), [input]), located.provenance));
								changed = true;
							case Virtual(name):
								target.instructions.push(new Located(Call(out, helperFor(out.type, out.type, name, true), [input]), located.provenance));
								changed = true;
							default: target.instructions.push(located);
						}
					default: target.instructions.push(located);
				}
				target.terminator = block.terminator;
				blocks.push(target);
			}
			rewritten.push(changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn);
		}
		return rewritten.concat(generated);
	}
}
