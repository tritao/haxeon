package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Expand bounded value constructors so newly constructed places can remain scalar. */
class IrValueConstructors {
	public static function rewrite(program:IrProgram):Void {
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var constructors:Map<String, IrFunction> = [], straight:Map<String, IrFunction> = [];
		for (fn in program.functions) {
			if (!StringTools.endsWith(fn.name, ".new") || fn.arguments.length == 0 || fn.result != Void) continue;
			var owner = switch fn.arguments[0].type { case Obj(name): objects.get(name); default: null; };
			if (owner == null || !owner.isValue || fn.blocks.length == 0 || fn.blocks.length > 16) continue;
			var safe = true, count = 0;
			for (block in fn.blocks) for (located in block.instructions) {
				count++;
				switch located.value {
					case Phi(_, _) if (fn.blocks.length == 1): safe = false;
					case BeginTry(_, _) | EndTry(_) | Catch(_): safe = false;
					default:
				}
			}
			if (safe && count <= 64) {
				if (fn.blocks.length == 1) {
					var term = fn.blocks[0].terminator;
					if (term != null) switch term.value { case Return(_): straight.set(fn.name, fn); default: }
				} else constructors.set(fn.name, fn);
			}
		}
		program.functions = [for (fn in program.functions) expand(expandStraightLine(fn, straight), constructors)];
	}

	static function expand(fn:IrFunction, constructors:Map<String, IrFunction>):IrFunction {
		var found = false;
		for (block in fn.blocks) {
			for (located in block.instructions) switch located.value {
				case Call(_, name, _) if (name != fn.name && constructors.exists(name)): found = true;
				default:
			}
			if (found) break;
		}
		if (!found) return fn;
		var next = 0, nextBlock = 0, blocks:Array<IrBlock> = [];
		for (arg in fn.arguments) if (arg.id >= next) next = arg.id + 1;
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				copy.instructions.push(located);
				var out = IrOperands.output(located.value);
				if (out != null && out.id >= next) next = out.id + 1;
			}
			copy.terminator = block.terminator; blocks.push(copy);
			if (block.id >= nextBlock) nextBlock = block.id + 1;
		}
		var index = 0, changes = 0;
		while (index < blocks.length) {
			var block = blocks[index], position = -1, callee:Null<IrFunction> = null;
			for (i in 0...block.instructions.length) switch block.instructions[i].value {
				case Call(_, name, args) if (constructors.exists(name) && name != fn.name):
					var target:IrFunction = cast constructors.get(name);
					if (args.length == target.arguments.length) { position = i; callee = target; break; }
				default:
			}
			if (callee == null) { index++; continue; }
			var expanded = IrInliner.expand(blocks, index, position, callee, next, nextBlock);
			next = expanded.nextValue;
			nextBlock = expanded.nextBlock;
			changes++;
			// Visit the continuation, not the cloned callee: recursive constructors
			// stay calls, while every independent call site can be expanded.
			index += callee.blocks.length + 1;
		}
		return changes == 0 ? fn : new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention);
	}

	static function expandStraightLine(fn:IrFunction, constructors:Map<String, IrFunction>):IrFunction {
		var next = 0;
		for (arg in fn.arguments) if (arg.id >= next) next = arg.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null && out.id >= next) next = out.id + 1;
		}
		var changed = false, blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) switch located.value {
				case Call(out, name, args) if (constructors.exists(name) && name != fn.name):
					var callee:IrFunction = cast constructors.get(name);
					if (args.length != callee.arguments.length) { copy.instructions.push(located); continue; }
					var mapping:Map<Int, IrValue> = [];
					for (i in 0...args.length) mapping.set(callee.arguments[i].id, args[i]);
					for (instruction in callee.blocks[0].instructions) {
						var result = IrOperands.output(instruction.value);
						if (result != null) mapping.set(result.id, new IrValue(next++, result.name, result.type));
						var mapped = IrInliner.remap(instruction.value, value -> {
							var found = mapping.get(value.id);
							if (found == null) throw 'Missing value constructor operand ${value.id}';
							return found;
						}, id -> id);
						copy.instructions.push(new Located(mapped, instruction.provenance));
					}
					copy.instructions.push(new Located(ConstVoid(out), located.provenance));
					changed = true;
				default: copy.instructions.push(located);
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}
}
