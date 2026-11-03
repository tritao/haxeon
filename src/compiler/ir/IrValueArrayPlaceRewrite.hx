package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceOrigin;

private typedef ArrayPlace = {final array:IrValue; final index:IrValue; final path:Array<String>;}

/** Lower element-place projections before rewriting the remaining value-copy array reads. */
class IrValueArrayPlaceRewrite {
	/** Locate frontend-marked mutable roots without treating ordinary element copies as live places. */
	public static function roots(fn:IrFunction, element:IrType):Map<Int, Bool> {
		var result:Map<Int, Bool> = [], raw:Map<Int, Bool> = [], arrayType:IrType = Array(element);
		for (block in fn.blocks) for (located in block.instructions) switch located.provenance.origin {
			case CompilerGenerated(reason) if (reason == IrGenerator.ArrayValuePlaceReason):
				switch located.value {
					case ArrayGet(out, array, _) if (Type.enumEq(array.type, arrayType) && Type.enumEq(out.type, element)):
						result.set(out.id, true);
					case Call(out, "__array_get_any", args) if (args.length == 2 && Type.enumEq(args[0].type, arrayType)):
						raw.set(out.id, true);
					default:
				}
			default:
		}
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case SafeCast(out, input) if (raw.exists(input.id) && Type.enumEq(out.type, element)): result.set(out.id, true);
			default:
		}
		return result;
	}

	public static function rewrite(fn:IrFunction, element:IrType, objects:IrObjectTable, helpers:IrValueArraySlotHelpers,
			methods:IrValueArrayPlaceMethods, roots:Map<Int, Bool>):IrFunction {
		var arrayType:IrType = Array(element), aliases:Map<Int, ArrayPlace> = [], raw:Map<Int, ArrayPlace> = [],
			nulls:Map<Int, Bool> = [], next = 0;
		function requiredPlace(id:Int):ArrayPlace {
			var place = aliases.get(id);
			if (place == null) throw 'Missing array place $id';
			return place;
		}
		function isValue(type:IrType):Bool return switch type {
			case Obj(name), Nullable(Obj(name)): var object = objects.get(name); object != null && object.isValue;
			default: false;
		};
		function isNullableScalar(type:IrType):Bool return switch type {
			case Nullable(I32 | I64 | F32 | F64 | Bool): true;
			default: false;
		};
		for (arg in fn.arguments) if (arg.id >= next) next = arg.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null && out.id >= next) next = out.id + 1;
			for (input in IrOperands.inputs(located.value)) if (input.id >= next) next = input.id + 1;
			switch located.value {
				case ConstNull(value): nulls.set(value.id, true);
				case ArrayGet(value, array, index) if (roots.exists(value.id)):
					if (!Type.enumEq(array.type, arrayType) || !Type.enumEq(value.type, element)) throw "Invalid array place root";
					aliases.set(value.id, {array: array, index: index, path: []});
				case Call(value, "__array_get_any", args) if (args.length == 2 && Type.enumEq(args[0].type, arrayType)):
					switch located.provenance.origin {
						case CompilerGenerated(reason) if (reason == IrGenerator.ArrayValuePlaceReason):
							raw.set(value.id, {array: args[0], index: args[1], path: []});
						default:
					}
				default:
			}
		}
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case SafeCast(out, input) if (roots.exists(out.id) && raw.exists(input.id)):
				var place = raw.get(input.id); if (place == null) throw "Missing checked array place"; aliases.set(out.id, place);
			default:
		}
		for (id in roots.keys()) if (!aliases.exists(id)) throw 'Missing array place root $id';
		var changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case FieldGet(out, owner, field) if (aliases.exists(owner.id) && isValue(out.type) && !aliases.exists(out.id)):
					var parent = requiredPlace(owner.id);
					aliases.set(out.id, {array: parent.array, index: parent.index, path: parent.path.concat([field])}); changed = true;
				case SafeCast(out, value) if (aliases.exists(value.id) && isValue(out.type) && !aliases.exists(out.id)):
					aliases.set(out.id, requiredPlace(value.id)); changed = true;
				case ToDyn(out, value) if (aliases.exists(value.id) && (Type.enumEq(out.type, element) || (switch (out.type) { case Dyn: true; default: false; })) && !aliases.exists(out.id)):
					aliases.set(out.id, requiredPlace(value.id)); changed = true;
				default:
			}
		}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value, handled = false, omit = false;
				switch instruction {
					case Call(out, "__array_get_any", _) if (raw.exists(out.id)):
						var place = raw.get(out.id); if (place == null) throw "Missing checked array place";
						var check = new IrValue(next++, "$array-place-check", Void);
						instruction = Call(check, helpers.checker(place.path, true), [place.array, place.index]); handled = true;
					case ArrayGet(out, _, _) if (roots.exists(out.id)):
						var place = requiredPlace(out.id), check = new IrValue(next++, "$array-place-check", Void);
						instruction = Call(check, helpers.checker(place.path, true), [place.array, place.index]); handled = true;
					case FieldGet(out, owner, field) if (aliases.exists(owner.id)):
						var place = requiredPlace(owner.id), path = place.path.concat([field]), check = new IrValue(next++, "$array-place-check", Void);
						target.instructions.push(new Located(Call(check, helpers.checker(path, false), [place.array, place.index]), located.provenance));
						if (isValue(out.type)) omit = true;
						else {
							var getter = isNullableScalar(out.type) ? methods.scalarGetter(out.type, path) : helpers.getter(helpers.slot(path));
							instruction = Call(out, getter, [place.array, place.index]);
						}
						handled = true;
					case FieldSet(owner, field, value) if (aliases.exists(owner.id)):
						var place = requiredPlace(owner.id), path = place.path.concat([field]), check = new IrValue(next++, "$array-place-check", Void);
						if (aliases.exists(value.id)) throw "Aliased place write requires component specialization";
						target.instructions.push(new Located(Call(check, helpers.checker(path, false), [place.array, place.index]), located.provenance));
						var setter = isValue(value.type) || isNullableScalar(value.type) ? methods.valueSetter(value.type, path) : helpers.setter(helpers.slot(path));
						instruction = Call(new IrValue(next++, "$array-place-write", Void), setter, [place.array, place.index, value]);
						handled = true;
					case SafeCast(out, value) if (roots.exists(out.id) && raw.exists(value.id)):
						omit = true; handled = true;
					case ToDyn(out, value) if (aliases.exists(value.id) && aliases.exists(out.id)):
						omit = true; handled = true;
					case Equal(out, left, right) if ((aliases.exists(left.id) && nulls.exists(right.id)) || (aliases.exists(right.id) && nulls.exists(left.id))):
						var place = requiredPlace(aliases.exists(left.id) ? left.id : right.id), present = new IrValue(next++, "$array-place-present", Bool),
							no = new IrValue(next++, "$array-place-false", Bool);
						target.instructions.push(new Located(Call(present, helpers.getter(helpers.slot(place.path, true)), [place.array, place.index]), located.provenance));
						target.instructions.push(new Located(ConstBool(no, false), located.provenance));
						instruction = Equal(out, present, no); handled = true;
					case SafeCast(out, value) if (aliases.exists(value.id) && aliases.exists(out.id)):
						var place = requiredPlace(value.id), check = new IrValue(next++, "$array-place-check", Void);
						instruction = Call(check, helpers.checker(place.path, true), [place.array, place.index]); handled = true;
					case MethodCall(out, owner, method, arguments) if (aliases.exists(owner.id)):
						for (argument in arguments) if (aliases.exists(argument.id)) throw "Array place argument requires component specialization";
						var place = requiredPlace(owner.id), name = methods.method(owner.type, method, place.path);
						instruction = Call(out, name, [place.array, place.index].concat(arguments)); handled = true;
					case ArraySet(array, index, value) if (aliases.exists(value.id)):
						var place = requiredPlace(value.id);
						if (place.path.length != 0 || place.array.id != array.id || place.index.id != index.id)
							throw "Array place writeback changed its destination";
						omit = true; handled = true;
					case Call(_, "__array_set_any", arguments) if (arguments.length == 3 && aliases.exists(arguments[2].id)):
						var place = requiredPlace(arguments[2].id);
						if (place.path.length != 0 || place.array.id != arguments[0].id || place.index.id != arguments[1].id)
							throw "Checked array place writeback changed its destination";
						omit = true; handled = true;
					default:
				}
				if (!handled) {
					for (input in IrOperands.inputs(instruction)) if (aliases.exists(input.id)) throw 'Array place ${input.id}:${input.type} escapes through ${Std.string(instruction)}';
					switch instruction {
						case Phi(_, inputs): for (input in inputs) if (aliases.exists(input.value.id)) throw "Array place phi requires component specialization";
						default:
					}
				}
				if (!omit) target.instructions.push(new Located(instruction, located.provenance));
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (aliases.exists(value.id)):
					throw "Array place escapes through a terminator";
				default:
			}
			target.terminator = block.terminator;
			blocks.push(target);
		}
		var debug = [for (binding in fn.debugBindings) if (!aliases.exists(binding.value.id)) binding];
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, debug, fn.inlineHint, fn.retention);
	}
}
