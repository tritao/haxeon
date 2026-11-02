package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Lower plain array element reads and writes after element-place operations have been separated. */
class IrValueArrayElementRewrite {
	public static function rewrite(fn:IrFunction, element:IrType, helpers:IrValueArrayElements):IrFunction {
		fn = rewriteCheckedSplice(fn, element, helpers);
		var arrayType:IrType = Array(element), next = 0, changed = false;
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null && output.id >= next) next = output.id + 1;
			for (input in IrOperands.inputs(located.value)) if (input.id >= next) next = input.id + 1;
		}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case ArrayGet(out, array, index) if (Type.enumEq(array.type, arrayType)):
						if (!Type.enumEq(out.type, element)) throw 'Wrong inline array read type ${out.type}';
						instruction = Call(out, helpers.getName(), [array, index]); changed = true;
					case ArraySet(array, index, value) if (Type.enumEq(array.type, arrayType)):
						if (!Type.enumEq(value.type, element)) throw 'Wrong inline array write type ${value.type}';
						instruction = Call(new IrValue(next++, "$array-element-write", Void), helpers.setName(), [array, index, value]); changed = true;
					case Call(out, "__array_push_ref", arguments) if (arguments.length == 2 && Type.enumEq(arguments[0].type, arrayType)):
						if (!Type.enumEq(arguments[1].type, element) || out.type != I32) throw "Wrong inline array push type";
						instruction = Call(out, helpers.pushName(), arguments); changed = true;
					case Call(out, "__array_unshift_ref", arguments) if (arguments.length == 2 && Type.enumEq(arguments[0].type, arrayType)):
						if (!Type.enumEq(arguments[1].type, element) || out.type != I32) throw "Wrong inline array unshift type";
						instruction = Call(out, helpers.unshiftName(), arguments); changed = true;
					case Call(out, name, arguments) if ((name == "__array_pop_ref" || name == "__array_shift_ref")
							&& arguments.length == 1 && Type.enumEq(arguments[0].type, arrayType) && Type.enumEq(out.type, element)):
						instruction = Call(out, name == "__array_pop_ref" ? helpers.popName() : helpers.shiftName(), arguments); changed = true;
					case Call(out, "__array_insert_ref", arguments) if (arguments.length == 3 && Type.enumEq(arguments[0].type, arrayType)):
						if (!Type.enumEq(arguments[2].type, element) || arguments[1].type != I32 || out.type != Void)
							throw "Wrong inline array insert type";
						instruction = Call(out, helpers.insertName(), arguments); changed = true;
					case Call(out, "__array_resize_ref" | "__array_resize_any", arguments) if (arguments.length == 2 && Type.enumEq(arguments[0].type, arrayType)):
						if (arguments[1].type != I32 || out.type != Void) throw "Wrong inline array resize type";
						instruction = Call(out, "__value_array_resize", arguments); changed = true;
					case Call(out, "__array_reverse_ref" | "__array_reverse_any", arguments) if (arguments.length == 1 && Type.enumEq(arguments[0].type, arrayType)):
						if (out.type != Void) throw "Wrong inline array reverse type";
						instruction = Call(out, "__value_array_reverse", arguments); changed = true;
					case Call(out, "__array_splice_ref", arguments) if (arguments.length == 3 && Type.enumEq(arguments[0].type, arrayType)):
						if (arguments[1].type != I32 || arguments[2].type != I32 || !Type.enumEq(out.type, arrayType))
							throw "Wrong inline array splice type";
						instruction = Call(out, IrValueArrayElements.spliceNativeName(element), arguments); changed = true;
					default:
				}
				target.instructions.push(new Located(instruction, located.provenance));
			}
			target.terminator = block.terminator;
			blocks.push(target);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	static function rewriteCheckedSplice(fn:IrFunction, element:IrType, helpers:IrValueArrayElements):IrFunction {
		var arrayType:IrType = Array(element), uses:Map<Int, Int> = [], removed:Map<Int, Bool> = [], changed = false;
		function use(value:IrValue):Void uses.set(value.id, (uses.exists(value.id) ? uses.get(value.id) : 0) + 1);
		for (block in fn.blocks) {
			for (located in block.instructions) {
				for (input in IrOperands.inputs(located.value)) use(input);
				switch located.value { case Phi(_, inputs): for (input in inputs) use(input.value); default: }
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): use(value);
				default:
			}
		}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var target = new IrBlock(block.id), position = 0;
			while (position < block.instructions.length) {
				var located = block.instructions[position], instruction = located.value;
				switch instruction {
					case Call(raw, name, args) if ((name == "__array_pop_ref" || name == "__array_shift_ref")
							&& args.length == 1 && Type.enumEq(args[0].type, arrayType) && raw.type == Dyn):
						if (position + 1 >= block.instructions.length) throw "Missing checked value array removal conversion";
						switch block.instructions[position + 1].value {
							case SafeCast(out, source) if (source.id == raw.id && Type.enumEq(out.type, element) && uses.get(raw.id) == 1):
								instruction = Call(out, name == "__array_pop_ref" ? helpers.popName() : helpers.shiftName(), args);
								removed.set(raw.id, true); position++; changed = true;
							default: throw "Invalid checked value array removal conversion";
						}
					case Call(raw, "__array_splice_any", args) if (args.length == 3 && Type.enumEq(args[0].type, arrayType)):
						if (position + 2 >= block.instructions.length) throw "Missing checked nullable array splice conversion";
						switch [block.instructions[position + 1].value, block.instructions[position + 2].value] {
							case [ToDyn(boxed, source), SafeCast(out, input)]
									if (source.id == raw.id && input.id == boxed.id && Type.enumEq(out.type, arrayType)
											&& args[1].type == I32 && args[2].type == I32 && uses.get(raw.id) == 1 && uses.get(boxed.id) == 1):
								instruction = Call(out, IrValueArrayElements.spliceNativeName(element), args);
								removed.set(raw.id, true); removed.set(boxed.id, true); position += 2; changed = true;
							default: throw "Invalid checked nullable array splice conversion";
						}
					default:
				}
				target.instructions.push(new Located(instruction, located.provenance)); position++;
			}
			target.terminator = block.terminator; blocks.push(target);
		}
		if (!changed) return fn;
		var debug = [for (binding in fn.debugBindings) if (!removed.exists(binding.value.id)) binding];
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, debug, fn.inlineHint, fn.retention);
	}
}
