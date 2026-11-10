package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Lower typed value-array range operations directly to the lane runtime. */
class IrValueArrayRangeRewrite {
	public static function rewrite(fn:IrFunction, element:IrType, factory:IrValueArrayFactory):IrFunction {
		var arrayType:IrType = Array(element), changed = false, blocks:Array<IrBlock> = [], uses:Map<Int, Int> = [];
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
		for (block in fn.blocks) {
			var replacement = new IrBlock(block.id), index = 0;
			while (index < block.instructions.length) {
				var located = block.instructions[index], output:Null<IrValue> = null,
					arguments:Null<Array<IrValue>> = null, operation:Null<String> = null, consumed = 1;
				switch located.value {
					case Call(out, name, args) if ((name == "__array_copy_ref" || name == "__array_slice_ref" || name == "__array_concat_ref")
							&& Type.enumEq(out.type, arrayType)):
						output = out; arguments = args; operation = rangeOperation(name);
					case Call(raw, name, args) if ((name == "__array_copy_any" || name == "__array_slice_any" || name == "__array_concat_any")
							&& args.length > 0 && Type.enumEq(args[0].type, arrayType) && index + 2 < block.instructions.length):
						switch [block.instructions[index + 1].value, block.instructions[index + 2].value] {
							case [ToDyn(boxed, source), SafeCast(out, input)] if (source.id == raw.id && input.id == boxed.id && Type.enumEq(out.type, arrayType)):
								if (uses.get(raw.id) != 1 || uses.get(boxed.id) != 1) throw "Checked array range intermediate escapes";
								output = out; arguments = args; operation = rangeOperation(name); consumed = 3;
							default:
						}
					default:
				}
				if (operation == null || output == null || arguments == null) replacement.instructions.push(located);
				else {
					var arity = operation == "copy" ? 1 : operation == "slice" ? 3 : 2;
					if (arguments.length != arity || !Type.enumEq(arguments[0].type, arrayType)
							|| (operation == "concat" && !Type.enumEq(arguments[1].type, arrayType)))
						throw 'Invalid inline array $operation operands';
					replacement.instructions.push(new Located(Call(output, factory.rangeNativeName(operation), arguments), located.provenance));
					changed = true;
				}
				index += consumed;
			}
			replacement.terminator = block.terminator;
			blocks.push(replacement);
		}
		return changed ? fn.derive(blocks) : fn;
	}

	static function rangeOperation(name:String):String {
		if (StringTools.startsWith(name, "__array_copy_")) return "copy";
		if (StringTools.startsWith(name, "__array_slice_")) return "slice";
		return "concat";
	}
}
