package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceOrigin;

/** Replace the boxed-element copy loop with the lane-preserving range operation. */
class IrValueArrayCopyRewrite {
	public static function rewrite(fn:IrFunction, element:IrType, factory:IrValueArrayFactory):IrFunction {
		var arrayType:IrType = Array(element), blocks:Map<Int, IrBlock> = [for (block in fn.blocks) block.id => block], uses:Map<Int, Int> = [];
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
		for (entry in fn.blocks) for (position in 0...entry.instructions.length) {
			var located = entry.instructions[position], output:IrValue = null, arguments:Array<IrValue> = null, operation:String = null,
				callEnd = position;
			switch located.value {
				case Call(out, "__array_copy_ref", args) if (Type.enumEq(out.type, arrayType)):
					output = out; arguments = args; operation = "copy";
				case Call(out, "__array_slice_ref", args) if (Type.enumEq(out.type, arrayType)):
					output = out; arguments = args; operation = "slice";
				case Call(out, "__array_concat_ref", args) if (Type.enumEq(out.type, arrayType)):
					output = out; arguments = args; operation = "concat";
				case Call(raw, nativeName, args) if ((nativeName == "__array_copy_any" || nativeName == "__array_slice_any"
						|| nativeName == "__array_concat_any") && args.length > 0 && Type.enumEq(args[0].type, arrayType)
						&& position + 2 < entry.instructions.length):
					switch [entry.instructions[position + 1].value, entry.instructions[position + 2].value] {
						case [ToDyn(boxed, source), SafeCast(out, input)]
								if (source.id == raw.id && input.id == boxed.id && Type.enumEq(out.type, arrayType)):
							if (uses.get(raw.id) != 1 || uses.get(boxed.id) != 1) throw "Checked array copy intermediate escapes";
							output = out; arguments = args; callEnd = position + 2;
							operation = nativeName == "__array_copy_any" ? "copy" : nativeName == "__array_slice_any" ? "slice" : "concat";
						default:
					}
				default:
			}
			if (operation == null) continue;
			var arity = operation == "copy" ? 1 : operation == "slice" ? 3 : 2;
			if (arguments.length != arity || !Type.enumEq(arguments[0].type, arrayType)
					|| (operation == "concat" && !Type.enumEq(arguments[1].type, arrayType)))
				throw 'Invalid inline array $operation operands';
			for (index in callEnd + 1...entry.instructions.length)
				if (!copyOrigin(entry.instructions[index].provenance.origin)) throw 'Unexpected instruction after array $operation';
			var entryTerminator = entry.terminator;
			if (entryTerminator == null || !copyOrigin(entryTerminator.provenance.origin)) throw 'Missing array $operation copy loop';
			var headerId = switch entryTerminator.value { case Jump(id): id; default: throw 'Invalid array $operation copy entry'; };
			var header = blocks.get(headerId);
			if (header == null || header.terminator == null || !copyOrigin(header.terminator.provenance.origin)) throw "Missing array copy loop header";
			var sizeId = -1, conditionId = -1;
			for (instruction in header.instructions) switch instruction.value {
				case ArraySize(out, array) if (array.id == output.id && copyOrigin(instruction.provenance.origin)): sizeId = out.id;
				case Less(out, _, size) if (size.id == sizeId && copyOrigin(instruction.provenance.origin)): conditionId = out.id;
				case Phi(_, _) if (phiOrigin(instruction.provenance.origin)):
				default: if (!copyOrigin(instruction.provenance.origin)) throw "Unexpected array copy loop header";
			}
			var endpoints = switch header.terminator.value {
				case Branch(condition, body, done) if (condition.id == conditionId && conditionId >= 0 && sizeId >= 0): {body: body, done: done};
				default: throw "Invalid array copy loop condition";
			};
			var removed:Map<Int, Bool> = [headerId => true], pending = [endpoints.body];
			while (pending.length > 0) {
				var id = pending.pop();
				if (id == headerId || id == endpoints.done || removed.exists(id)) continue;
				var current = blocks.get(id);
				if (current == null || current.terminator == null || !copyOrigin(current.terminator.provenance.origin))
					throw "Invalid array copy loop body";
				removed.set(id, true);
				for (instruction in current.instructions) switch instruction.value {
					case Phi(_, _) if (phiOrigin(instruction.provenance.origin)):
					default: if (!copyOrigin(instruction.provenance.origin)) throw "Unexpected array copy loop instruction";
				}
				switch current.terminator.value {
					case Jump(next): pending.push(next);
					case Branch(_, yes, no): pending.push(yes); pending.push(no);
					default: throw "Invalid array copy loop exit";
				}
			}
			var loopValues:Map<Int, Bool> = [];
			for (index in callEnd + 1...entry.instructions.length) {
				var out = IrOperands.output(entry.instructions[index].value); if (out != null) loopValues.set(out.id, true);
			}
			for (id in removed.keys()) {
				var removedBlock = blocks.get(id);
				if (removedBlock == null) throw 'Missing array copy loop block $id';
				for (instruction in removedBlock.instructions) {
					var out = IrOperands.output(instruction.value); if (out != null) loopValues.set(out.id, true);
				}
			}
			for (block in fn.blocks) if (!removed.exists(block.id)) {
				var limit = block.id == entry.id ? position + 1 : block.instructions.length;
				for (index in 0...limit) {
					var instruction = block.instructions[index].value;
					for (input in IrOperands.inputs(instruction)) if (loopValues.exists(input.id)) throw "Array copy loop value escapes";
					switch instruction {
						case Phi(_, inputs): for (input in inputs) if (loopValues.exists(input.value.id) || removed.exists(input.block))
							throw "Array copy loop value escapes through a phi";
						default:
					}
				}
				if (block.id != entry.id && block.terminator != null) switch block.terminator.value {
					case Jump(target) if (removed.exists(target)): throw "External edge into array copy loop";
					case Branch(value, yes, no):
						if (loopValues.exists(value.id) || removed.exists(yes) || removed.exists(no)) throw "External edge into array copy loop";
					case Return(value), Throw(value), Rethrow(value) if (loopValues.exists(value.id)): throw "Array copy loop result escapes";
					default:
				}
			}
			var result:Array<IrBlock> = [];
			for (block in fn.blocks) if (!removed.exists(block.id)) {
				if (block.id != entry.id) result.push(block);
				else {
					var replacement = new IrBlock(block.id);
					for (index in 0...position) replacement.instructions.push(block.instructions[index]);
					replacement.instructions.push(new Located(Call(output, factory.rangeNativeName(operation), arguments), located.provenance));
					replacement.terminator = new Located(Jump(endpoints.done), entryTerminator.provenance);
					result.push(replacement);
				}
			}
			var debug = [for (binding in fn.debugBindings) if (!loopValues.exists(binding.value.id)) binding];
			return rewrite(new IrFunction(fn.name, fn.arguments, fn.result, result, debug, fn.inlineHint, fn.retention), element, factory);
		}
		return fn;
	}

	static function copyOrigin(origin:SourceOrigin):Bool return switch origin {
		case CompilerGenerated(reason): reason == IrGenerator.ArrayValueCopyReason;
		default: false;
	};
	static function phiOrigin(origin:SourceOrigin):Bool return switch origin {
		case CompilerGenerated("ssa-phi"): true;
		default: false;
	};
}
