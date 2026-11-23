package compiler.ir.passes.enums;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.TypeKey;
import compiler.ir.verify.IrVerifier;

/** Materialize the nominal boxed enum only at a genuine Dynamic/reflection/native boundary. */
@:access(compiler.ir.model.IrBuilder)
@:nullSafety(Strict)
class IrInlineEnumEscapes {
	public static function boxName(name:String):String return IrInlineEnumCaseAccess.HELPER_PREFIX + "box:" + name;
	public static function unboxName(name:String):String return IrInlineEnumCaseAccess.HELPER_PREFIX + "unbox:" + name;

	/**
	 * The box and unbox adapters of each enum `enums` store inline, by name; each made through `derive` when given (a session's
	 * `IrFunctionStages.derived`), which makes it only when what it reads changed.
	 */
	public static function functions(enums:Array<IrEnum>, objects:IrObjectTable, planner:IrInlineEnumLayout,
			?derive:(name:String, make:() -> IrFunction) -> IrFunction):Array<IrFunction> {
		var declarations = [for (declaration in enums) declaration.name => declaration], result:Array<IrFunction> = [];
		var names = [for (declaration in enums) if (declaration.inlineStorage != null) declaration.name];
		names.sort(Reflect.compare);
		var made = derive ?? (_, make) -> make();
		function converted(builder:IrBuilder, value:IrValue, logical:IrType, toStorage:Bool):IrValue {
			var nested = switch logical {
				case Enum(name), Nullable(Enum(name)): declarations.get(name);
				default: null;
			};
			var nestedStorage = nested == null ? null : nested.inlineStorage;
			if (nested != null && nestedStorage != null) {
				if (toStorage) return builder.call(unboxName(nested.name), [builder.toDyn(value)],
					Obj(nestedStorage));
				return builder.safeCast(builder.call(boxName(nested.name), [value], Dyn), logical);
			}
			if (!IrVerifier.sameType(value.type, logical))
				throw new InternalError('Missing inline enum escape conversion from ${value.type} to $logical');
			return value;
		}
		for (name in names) {
			var found = declarations.get(name), shape = planner.shape(name);
			if (found == null)
				throw new InternalError('Invalid enum escape storage for "$name"');
			var declaration:IrEnum = found, storageName = found.inlineStorage;
			if (shape == null || storageName == null || shape.valueObject.name != storageName)
				throw new InternalError('Invalid enum escape storage for "$name"');
			IrInlineEnumStorage.validate(declaration, objects);
			var storage:IrType = Obj(storageName), access = new IrInlineEnumCaseAccess(shape, objects);
			result.push(made(boxName(name), () -> {
				var box = new IrBuilder(),
					value = box.argument("value", storage),
					tag = box.fieldGet(value, "tag", I32);
				var nil = box.createBlock(), present = box.createBlock();
				box.branch(box.equal(tag, box.constInt(0)), nil, present);
				box.select(nil);
				box.returnValue(box.constNull(Dyn));
				box.select(present);
				for (constructor in 0...declaration.cases.length) {
					var boxCase = box.createBlock(), boxNext = box.createBlock();
					box.branch(box.equal(tag, box.constInt(constructor + 1)), boxCase, boxNext);
					box.select(boxCase);
					var boxArguments:Array<IrValue> = [];
					for (field in 0...declaration.cases[constructor].params.length)
						boxArguments.push(converted(box, access.field(box, value, constructor, field),
							declaration.cases[constructor].params[field], false));
					var boxed = box.temporary(Enum(name));
					box.emit(MakeEnum(boxed, name, constructor, boxArguments));
					box.returnValue(box.toDyn(boxed));
					box.select(boxNext);
				}
				box.throwValue(box.toDyn(box.constString("Invalid inline enum tag")));
				new IrFunction(boxName(name), box.arguments, Dyn, box.blocks, Provider(TypeKey.of(Enum(name)),
					ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, "box")));
			}));
			result.push(made(unboxName(name), () -> {
				var unbox = new IrBuilder(),
					input = unbox.argument("value", Dyn),
					absent = unbox.createBlock(),
					populated = unbox.createBlock();
				unbox.branch(unbox.equal(input, unbox.constNull(Dyn)), absent, populated);
				unbox.select(absent);
				unbox.returnValue(access.nullValue(unbox));
				unbox.select(populated);
				var checked = unbox.safeCast(input, Enum(name)), index = unbox.temporary(I32);
				unbox.emit(EnumIndex(index, checked));
				for (constructor in 0...declaration.cases.length) {
					var unboxCase = unbox.createBlock(), unboxNext = unbox.createBlock();
					unbox.branch(unbox.equal(index, unbox.constInt(constructor)), unboxCase, unboxNext);
					unbox.select(unboxCase);
					var unboxArguments:Array<IrValue> = [];
					for (field in 0...declaration.cases[constructor].params.length) {
						var logical = declaration.cases[constructor].params[field],
							parameter = unbox.temporary(logical);
						unbox.emit(EnumField(parameter, checked, constructor, field));
						unboxArguments.push(converted(unbox, parameter, logical, true));
					}
					unbox.returnValue(access.construct(unbox, constructor, unboxArguments));
					unbox.select(unboxNext);
				}
				unbox.throwValue(unbox.toDyn(unbox.constString("Invalid enum case index")));
				new IrFunction(unboxName(name), unbox.arguments, storage, unbox.blocks,
					Provider(TypeKey.of(Enum(name)),
					ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, "unbox")));
			}));
		}
		return result;
	}
}
