package compiler.ir;

import compiler.Provides.ProviderOperation;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Check Dynamic-to-reference casts before target-specific casts, so failure remains catchable. */
class IrCheckedDynamicCasts {
	public static inline final PREFIX = "$checked-dynamic-cast:";
	public static function rewrite(functions:Array<IrFunction>, objects:Array<IrObject>, checkObjects:Bool, ?existingFunctions:Array<IrFunction>,
			checkValueObjects:Bool = false, checkFunctionCasts:Bool = false):Array<IrFunction> {
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
			var test = switch checkedType { case Function(_, _): "__closure_is_of_type"; default: "__std_is_of_type"; };
			builder.branch(builder.call(test, [input, builder.typeValue(checkedType)], Bool), accepted, rejected);
			builder.select(accepted);
			builder.returnValue(builder.safeCast(input, type));
			builder.select(rejected);
			builder.terminate(Throw(builder.toDyn(builder.constString('Invalid cast to $typeName'))));
			generated.push(new IrFunction(name, builder.arguments, type, builder.blocks, Serves(TypeKey.of(type), ProviderOperation.CheckedCast)));
			return name;
		}
		function replacement(located:Located<IrInstruction>):Null<Array<Located<IrInstruction>>>
			return switch located.value {
				case SafeCast(out, input) if ((switch (input.type) { case Dyn: true; default: false; })):
					switch out.type {
						case Obj(name) if (declarations.exists(name) && (checkObjects || (checkValueObjects && declarations.get(name).isValue))):
							var declaration = declarations.get(name);
							if (declaration == null) throw 'Missing cast target "$name"';
							[new Located(Call(out, helperFor(out.type, out.type, name, !declaration.isValue), [input]), located.provenance)];
						case Nullable(Obj(name)) if (checkValueObjects && declarations.exists(name) && declarations.get(name).isValue):
							[new Located(Call(out, helperFor(out.type, Obj(name), name, true), [input]), located.provenance)];
						case RawPtr:
							[new Located(Call(out, helperFor(out.type, out.type, "hl.Bytes", true), [input]), located.provenance)];
						case Function(_, _) if (checkFunctionCasts):
							[new Located(Call(out, helperFor(out.type, out.type, Std.string(out.type), false), [input]), located.provenance)];
						case Nullable(Function(_, _)) if (checkFunctionCasts):
							var inner = switch out.type { case Nullable(value): value; default: throw "Invalid nullable function cast"; };
							[new Located(Call(out, helperFor(out.type, inner, Std.string(inner), true), [input]), located.provenance)];
						case Virtual(name):
							[new Located(Call(out, helperFor(out.type, out.type, name, true), [input]), located.provenance)];
						default: null;
					}
				default: null;
			};
		var rewritten:Array<IrFunction> = [for (fn in functions) IrFunctionRewrite.instructions(fn, replacement)];
		return rewritten.concat(generated);
	}
}
