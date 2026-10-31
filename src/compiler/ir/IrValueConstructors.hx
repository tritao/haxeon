package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Expand straight-line value constructors so newly constructed places can remain scalar. */
class IrValueConstructors {
	public static function rewrite(program:IrProgram):Void {
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var constructors:Map<String, IrFunction> = [];
		for (fn in program.functions) {
			if (!StringTools.endsWith(fn.name, ".new") || fn.arguments.length == 0 || fn.result != Void || fn.blocks.length != 1) continue;
			var owner = switch fn.arguments[0].type { case Obj(name): objects.get(name); default: null; };
			if (owner == null || !owner.isValue || fn.blocks[0].instructions.length > 64 || fn.blocks[0].terminator == null) continue;
			switch fn.blocks[0].terminator.value { case Return(_): default: continue; }
			var safe = true;
			for (located in fn.blocks[0].instructions) switch located.value {
				case Phi(_, _) | BeginTry(_, _) | EndTry(_) | Catch(_): safe = false;
				default:
			}
			if (safe) constructors.set(fn.name, fn);
		}
		program.functions = [for (fn in program.functions) expand(fn, constructors)];
	}

	static function expand(fn:IrFunction, constructors:Map<String, IrFunction>):IrFunction {
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
