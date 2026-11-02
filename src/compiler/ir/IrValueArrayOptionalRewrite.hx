package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

private typedef OptionalArrayAccess = {final block:Int; final position:Int; final array:IrValue; final index:Null<IrValue>; final operation:String;}
private typedef OptionalBox = {final block:Int; final position:Int; final wrapper:IrValue;}

/** Keep optional-scalar wrappers in components when they cross a typed array boundary. */
class IrValueArrayOptionalRewrite {
	public static function rewrite(fn:IrFunction, element:IrType, components:IrValueArrayOptionalComponents):IrFunction {
		var name = switch element { case Nullable(Obj(value)): value; default: throw "Expected a nullable struct element"; },
			arrayType:IrType = Array(element), wrapperType = components.wrapperType(), reads:Map<Int, OptionalArrayAccess> = [],
			boxes:Map<Int, OptionalBox> = [], unboxes:Map<Int, IrValue> = [], writes:Map<Int, IrValue> = [],
			anyReads:Map<Int, OptionalArrayAccess> = [], castSources:Map<Int, Int> = [], rawReads:Map<Int, Int> = [],
			dynamicValues:Map<Int, {boxed:Int, block:Int, position:Int}> = [], dynamicWrites:Map<Int, IrValue> = [], dynamicBoxes:Map<Int, Bool> = [],
			uses:Map<Int, Int> = [], next = 0;
		function use(value:IrValue):Void uses.set(value.id, (uses.exists(value.id) ? uses.get(value.id) : 0) + 1);
		function readAt(id:Int):OptionalArrayAccess {
			var value = reads.get(id);
			if (value == null) throw 'Missing optional array read $id';
			return value;
		}
		function boxAt(id:Int):OptionalBox {
			var value = boxes.get(id);
			if (value == null) throw 'Missing optional array box $id';
			return value;
		}
		function unboxed(id:Int):IrValue {
			var value = unboxes.get(id);
			if (value == null) throw 'Missing optional array unbox $id';
			return value;
		}
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		for (block in fn.blocks) {
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value, out = IrOperands.output(instruction);
				if (out != null && out.id >= next) next = out.id + 1;
				for (input in IrOperands.inputs(instruction)) { use(input); if (input.id >= next) next = input.id + 1; }
				switch instruction {
					case Phi(_, inputs): for (input in inputs) use(input.value);
					case ArrayGet(value, array, index) if (Type.enumEq(array.type, arrayType) && Type.enumEq(value.type, element)):
						reads.set(value.id, {block: block.id, position: position, array: array, index: index, operation: "get"});
					case Call(value, "__array_get_any", args) if (args.length == 2 && Type.enumEq(args[0].type, arrayType)):
						anyReads.set(value.id, {block: block.id, position: position, array: args[0], index: args[1], operation: "get"});
					case Call(value, nativeName, args) if ((nativeName == "__array_pop_ref" || nativeName == "__array_shift_ref"
							|| nativeName == "__array_pop_any" || nativeName == "__array_shift_any")
							&& args.length == 1 && Type.enumEq(args[0].type, arrayType)):
						var read:OptionalArrayAccess = {block: block.id, position: position, array: args[0], index: null,
							operation: nativeName.indexOf("pop") >= 0 ? "pop" : "shift"};
						if (Type.enumEq(value.type, element)) reads.set(value.id, read); else anyReads.set(value.id, read);
					case Call(value, helper, args) if (helper == IrOptionalValueFlow.boxName(name) && args.length == 1
							&& Type.enumEq(value.type, element) && Type.enumEq(args[0].type, wrapperType)):
						boxes.set(value.id, {block: block.id, position: position, wrapper: args[0]});
					case ToDyn(out, value) if (Type.enumEq(value.type, element) && out.type == Dyn):
						dynamicValues.set(out.id, {boxed: value.id, block: block.id, position: position});
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): use(value);
				default:
			}
		}
		for (block in fn.blocks) for (position in 0...block.instructions.length) switch block.instructions[position].value {
			case SafeCast(out, value) if (Type.enumEq(out.type, element) && anyReads.exists(value.id) && uses.get(value.id) == 1):
				var read = anyReads.get(value.id);
				if (read.block == block.id && read.position < position) { reads.set(out.id, read); castSources.set(out.id, value.id); }
			default:
		}
		for (block in fn.blocks) for (position in 0...block.instructions.length) switch block.instructions[position].value {
			case Call(out, helper, args) if (helper == IrOptionalValueFlow.unboxName(name) && args.length == 1 && reads.exists(args[0].id)
					&& Type.enumEq(out.type, wrapperType) && uses.get(args[0].id) == 1):
				var read = readAt(args[0].id);
				if (read.block == block.id && read.position < position) {
					unboxes.set(args[0].id, out);
					if (castSources.exists(args[0].id)) rawReads.set(castSources.get(args[0].id), args[0].id);
				}
			case ArraySet(array, _, value) if (Type.enumEq(array.type, arrayType) && boxes.exists(value.id) && uses.get(value.id) == 1):
				var box = boxAt(value.id);
				if (box.block == block.id && box.position < position && privateWrapper(fn, box.wrapper, block.id, box.position, value.id))
					writes.set(value.id, box.wrapper);
			case Call(out, nativeName, args) if (mutation(nativeName, args, out, arrayType) != null
					&& boxes.exists(args[args.length - 1].id) && uses.get(args[args.length - 1].id) == 1):
				var value = args[args.length - 1], box = boxAt(value.id);
				if (box.block == block.id && box.position < position && privateWrapper(fn, box.wrapper, block.id, box.position, value.id))
					writes.set(value.id, box.wrapper);
			case Call(out, nativeName, args) if (mutation(nativeName, args, out, arrayType) != null
					&& dynamicValues.exists(args[args.length - 1].id) && uses.get(args[args.length - 1].id) == 1):
				var conversion = dynamicValues.get(args[args.length - 1].id);
				if (conversion == null) throw "Missing optional dynamic array conversion";
				var box = boxes.get(conversion.boxed);
				if (box != null && uses.get(conversion.boxed) == 1 && box.block == block.id && conversion.block == block.id
						&& box.position < conversion.position && conversion.position < position
						&& privateWrapper(fn, box.wrapper, block.id, box.position, conversion.boxed)) {
					dynamicWrites.set(args[args.length - 1].id, box.wrapper); dynamicBoxes.set(conversion.boxed, true);
				}
			default:
		}
		if (!unboxes.keys().hasNext() && !writes.keys().hasNext() && !dynamicWrites.keys().hasNext()) return fn;
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value, omit = false;
				switch instruction {
					case ArrayGet(out, array, index) if (unboxes.exists(out.id)):
						instruction = Call(unboxed(out.id), components.getName(), [array, index]);
					case Call(out, nativeName, args) if ((rawReads.exists(out.id) || unboxes.exists(out.id))
							&& (nativeName == "__array_get_any" || nativeName == "__array_pop_ref" || nativeName == "__array_shift_ref"
								|| nativeName == "__array_pop_any" || nativeName == "__array_shift_any")):
						var id = out.id;
						if (rawReads.exists(out.id)) {
							var source = rawReads.get(out.id);
							if (source == null) throw "Missing raw optional array read";
							id = source;
						}
						var read = readAt(id);
						var helper = switch read.operation { case "get": components.getName(); case "pop": components.popName();
							case "shift": components.shiftName(); default: throw "Invalid optional array read"; };
						instruction = Call(unboxed(id), helper, args);
					case SafeCast(out, _) if (unboxes.exists(out.id) && castSources.exists(out.id)):
						omit = true;
					case Call(_, helper, args) if (helper == IrOptionalValueFlow.unboxName(name) && args.length == 1 && unboxes.exists(args[0].id)):
						omit = true;
					case Call(out, helper, _) if (helper == IrOptionalValueFlow.boxName(name) && (writes.exists(out.id) || dynamicBoxes.exists(out.id))):
						omit = true;
					case ToDyn(out, _) if (dynamicWrites.exists(out.id)):
						omit = true;
					case ArraySet(array, index, value) if (writes.exists(value.id)):
						instruction = Call(new IrValue(next++, "$optional-array-write", Void), components.setName(), [array, index, writes.get(value.id)]);
					case Call(out, nativeName, args) if (mutation(nativeName, args, out, arrayType) != null
							&& (writes.exists(args[args.length - 1].id) || dynamicWrites.exists(args[args.length - 1].id))):
						var kind = mutation(nativeName, args, out, arrayType), value = args[args.length - 1],
							wrapper = writes.exists(value.id) ? writes.get(value.id) : dynamicWrites.get(value.id),
							arguments = args.slice(0, args.length - 1).concat([wrapper]);
						var helper = switch kind {
							case "set": components.setName();
							case "push": components.pushName();
							case "insert": components.insertName();
							case "unshift": components.unshiftName();
							default: throw "Invalid nullable array operation";
						};
						instruction = Call(out, helper, arguments);
					default:
				}
				if (!omit) target.instructions.push(new Located(instruction, located.provenance));
			}
			target.terminator = block.terminator; blocks.push(target);
		}
		var debug = [for (binding in fn.debugBindings) if (!unboxes.exists(binding.value.id) && !writes.exists(binding.value.id)
			&& !rawReads.exists(binding.value.id) && !dynamicWrites.exists(binding.value.id) && !dynamicBoxes.exists(binding.value.id)) binding];
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, debug, fn.inlineHint, fn.retention);
	}

	static function mutation(name:String, args:Array<IrValue>, output:IrValue, arrayType:IrType):Null<String> {
		if (args.length == 0 || !Type.enumEq(args[0].type, arrayType)) return null;
		return switch name {
			case "__array_set_any" if (args.length == 3 && args[1].type == I32 && output.type == Void): "set";
			case "__array_push_ref" | "__array_push_any" if (args.length == 2 && output.type == I32): "push";
			case "__array_unshift_ref" | "__array_unshift_any" if (args.length == 2 && output.type == I32): "unshift";
			case "__array_insert_ref" | "__array_insert_any" if (args.length == 3 && args[1].type == I32 && output.type == Void): "insert";
			default: null;
		};
	}

	static function privateWrapper(fn:IrFunction, wrapper:IrValue, blockId:Int, boxPosition:Int, boxValue:Int):Bool {
		var allocated = false;
		for (block in fn.blocks) {
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				switch instruction {
					case NewObject(out, _) if (out.id == wrapper.id):
						if (block.id != blockId || position >= boxPosition) return false;
						allocated = true;
					case Phi(_, inputs): for (input in inputs) if (input.value.id == wrapper.id) return false;
					default:
				}
				for (input in IrOperands.inputs(instruction)) if (input.id == wrapper.id) {
					var allowed = block.id == blockId && (switch instruction {
						case FieldSet(owner, _, value) if (owner.id == wrapper.id && value.id != wrapper.id && position < boxPosition): true;
						case Call(out, _, _) if (out.id == boxValue && position == boxPosition): true;
						default: false;
					});
					if (!allowed) return false;
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (value.id == wrapper.id): return false;
				default:
			}
		}
		return allocated;
	}
}
