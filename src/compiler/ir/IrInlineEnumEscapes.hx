package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;

/** Materialize the nominal boxed enum only at a genuine Dynamic/reflection/native boundary. */
@:access(compiler.ir.IrBuilder)
class IrInlineEnumEscapes {
	public static function boxName(name:String):String return IrInlineEnumCaseAccess.HELPER_PREFIX + "box:" + name;
	public static function unboxName(name:String):String return IrInlineEnumCaseAccess.HELPER_PREFIX + "unbox:" + name;

	public static function functions(enums:Array<IrEnum>, objects:IrObjectTable, planner:IrInlineEnumLayout):Array<IrFunction> {
		var declarations = [for (declaration in enums) declaration.name => declaration], result:Array<IrFunction> = [];
		var names = [for (declaration in enums) if (declaration.inlineStorage != null) declaration.name]; names.sort(Reflect.compare);
		function converted(builder:IrBuilder, value:IrValue, logical:IrType, toStorage:Bool):IrValue {
			var nested = switch logical { case Enum(name), Nullable(Enum(name)): declarations.get(name); default: null; };
			if (nested != null && nested.inlineStorage != null) {
				if (toStorage) return builder.call(unboxName(nested.name), [builder.toDyn(value)], Obj(nested.inlineStorage));
				return builder.safeCast(builder.call(boxName(nested.name), [value], Dyn), logical);
			}
			if (!IrVerifier.sameType(value.type, logical)) throw 'Missing inline enum escape conversion from ${value.type} to $logical';
			return value;
		}
		for (name in names) {
			var declaration = declarations.get(name), shape = planner.shape(name);
			if (declaration == null || shape == null || shape.valueObject.name != declaration.inlineStorage) throw 'Invalid enum escape storage for "$name"';
			IrInlineEnumStorage.validate(declaration, objects);
			var storage:IrType = Obj(declaration.inlineStorage), access = new IrInlineEnumCaseAccess(shape, objects);
			var box = new IrBuilder(), value = box.argument("value", storage), tag = box.fieldGet(value, "tag", I32);
			var nil = box.createBlock(), present = box.createBlock(); box.branch(box.equal(tag, box.constInt(0)), nil, present);
			box.select(nil); box.returnValue(box.constNull(Dyn)); box.select(present);
			var unbox = new IrBuilder(), input = unbox.argument("value", Dyn), absent = unbox.createBlock(), populated = unbox.createBlock();
			unbox.branch(unbox.equal(input, unbox.constNull(Dyn)), absent, populated);
			unbox.select(absent); unbox.returnValue(access.nullValue(unbox)); unbox.select(populated);
			var checked = unbox.safeCast(input, Enum(name)), index = unbox.temporary(I32); unbox.emit(EnumIndex(index, checked));
			for (constructor in 0...declaration.cases.length) {
				var boxCase = box.createBlock(), boxNext = box.createBlock();
				box.branch(box.equal(tag, box.constInt(constructor + 1)), boxCase, boxNext); box.select(boxCase);
				var boxArguments:Array<IrValue> = [];
				for (field in 0...declaration.cases[constructor].params.length)
					boxArguments.push(converted(box, access.field(box, value, constructor, field), declaration.cases[constructor].params[field], false));
				var boxed = box.temporary(Enum(name)); box.emit(MakeEnum(boxed, name, constructor, boxArguments));
				box.returnValue(box.toDyn(boxed)); box.select(boxNext);
				var unboxCase = unbox.createBlock(), unboxNext = unbox.createBlock();
				unbox.branch(unbox.equal(index, unbox.constInt(constructor)), unboxCase, unboxNext); unbox.select(unboxCase);
				var unboxArguments:Array<IrValue> = [];
				for (field in 0...declaration.cases[constructor].params.length) {
					var logical = declaration.cases[constructor].params[field], parameter = unbox.temporary(logical);
					unbox.emit(EnumField(parameter, checked, constructor, field));
					unboxArguments.push(converted(unbox, parameter, logical, true));
				}
				unbox.returnValue(access.construct(unbox, constructor, unboxArguments)); unbox.select(unboxNext);
			}
			box.throwValue(box.toDyn(box.constString("Invalid inline enum tag")));
			unbox.throwValue(unbox.toDyn(unbox.constString("Invalid enum case index")));
			result.push(new IrFunction(boxName(name), box.arguments, Dyn, box.blocks, Ordinary));
			result.push(new IrFunction(unboxName(name), unbox.arguments, storage, unbox.blocks, Ordinary));
		}
		return result;
	}
}
