package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Expand bounded value constructors so newly constructed places can remain scalar. */
class IrValueConstructors {
	public static function rewrite(program:IrProgram):Void {
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var constructors:Map<String, IrFunction> = [],
			straight:Map<String, IrFunction> = [];
		for (fn in program.functions) {
			var owner = switch fn.result {
				case Obj(name): objects.get(name);
				default: null;
			};
			if (owner == null || !owner.isValue || fn.name != owner.name + ".new" || fn.blocks.length == 0
				|| fn.blocks.length > 16)
				continue;
			var safe = true, count = 0;
			for (block in fn.blocks)
				for (located in block.instructions) {
					count++;
					switch located.value {
						case Phi(_, _) if (fn.blocks.length == 1):
							safe = false;
						case BeginTry(_, _, _) | EndTry(_, _) | Catch(_):
							safe = false;
						default:
					}
				}
			if (safe && count <= 64) {
				if (fn.blocks.length == 1) {
					var term = fn.blocks[0].terminator;
					if (term != null)
						switch term.value {
							case Return(_):
								straight.set(fn.name, fn);
							default:
						}
				} else
					constructors.set(fn.name, fn);
			}
		}
		// Prepare nested straight-line bodies first. Expanding only the caller once leaves constructor calls
		// introduced by an outer constructor boxed even when the complete value never escapes.
		var prepared = prepareStraightLine(straight),
			branches:Map<String, IrFunction> = [];
		for (name => fn in constructors)
			branches.set(name, expandStraightLine(fn, prepared));
		program.functions = [for (fn in program.functions) expand(expandStraightLine(fn, prepared), branches)];
	}

	/** Expand acyclic nested constructor bodies once, with a size bound to avoid exponential code growth. */
	static function prepareStraightLine(constructors:Map<String, IrFunction>):Map<String, IrFunction> {
		var prepared:Map<String, IrFunction> = [],
			visiting:Map<String, Bool> = [];
		function prepare(name:String):Null<IrFunction> {
			if (prepared.exists(name))
				return prepared.get(name);
			if (visiting.exists(name))
				return null;
			var fn = constructors.get(name);
			if (fn == null)
				return null;
			visiting.set(name, true);
			var children:Map<String, IrFunction> = [];
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, child, _) if (child.name != name && constructors.exists(child.name)):
							var nested = prepare(child.name);
							if (nested != null)
								children.set(child.name, nested);
						default:
					}
			var result = expandStraightLine(fn, children), count = 0;
			for (block in result.blocks)
				count += block.instructions.length;
			if (count > 256)
				result = fn;
			visiting.remove(name);
			prepared.set(name, result);
			return result;
		}
		var names = [for (name in constructors.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			prepare(name);
		return prepared;
	}

	static function expand(fn:IrFunction, constructors:Map<String, IrFunction>):IrFunction {
		var found = false;
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case Call(_, name, _) if (name.name != fn.name && constructors.exists(name.name)):
						found = true;
					default:
				}
			if (found)
				break;
		}
		if (!found)
			return fn;
		var next = 0, nextBlock = 0, blocks:Array<IrBlock> = [];
		for (arg in fn.arguments)
			if (arg.id >= next)
				next = arg.id + 1;
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				copy.instructions.push(located);
				var out = IrOperands.output(located.value);
				if (out != null && out.id >= next)
					next = out.id + 1;
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
			if (block.id >= nextBlock)
				nextBlock = block.id + 1;
		}
		var index = 0, changes = 0;
		while (index < blocks.length) {
			var block = blocks[index], position = -1, callee:Null<IrFunction> = null;
			for (i in 0...block.instructions.length)
				switch block.instructions[i].value {
					case Call(_, name, args) if (constructors.exists(name.name) && name.name != fn.name):
						var target:IrFunction = cast constructors.get(name.name);
						if (args.length == target.arguments.length) {
							position = i;
							callee = target;
							break;
						}
					default:
				}
			if (callee == null) {
				index++;
				continue;
			}
			var expanded = IrInliner.expand(blocks, index, position, callee, next, nextBlock);
			next = expanded.nextValue;
			nextBlock = expanded.nextBlock;
			changes++;
			// Visit the continuation, not the cloned callee: recursive constructors
			// stay calls, while every independent call site can be expanded.
			index += callee.blocks.length + 1;
		}
		return changes == 0 ? fn : fn.withBlocks(blocks);
	}

	static function expandStraightLine(fn:IrFunction, constructors:Map<String, IrFunction>):IrFunction {
		// The first free value id is found only once a call is expanded; only the blocks with one are copied.
		var next = -1;
		return IrFunctionRewrite.instructions(fn, function(located) {
			return switch located.value {
				case Call(out, name, args) if (constructors.exists(name.name) && name.name != fn.name):
					var callee:IrFunction = cast constructors.get(name.name),
						single:IrBlock = callee.blocks[0],
						returned = straightLineResult(callee, args.length);
					if (returned == null) null;
					else {
						if (next < 0)
							next = firstFreeValue(fn);
						var mapping:Map<Int, IrValue> = [],
							expanded:Array<Located<IrInstruction>> = [];
						for (i in 0...args.length)
							mapping.set(callee.arguments[i].id, args[i]);
						for (instruction in single.instructions) {
							var result = IrOperands.output(instruction.value);
							if (result != null)
								mapping.set(result.id,
									result.id == returned.id ? out : new IrValue(next++, result.name, result.type));
							var mapped = IrInliner.remap(instruction.value, value -> {
								var found = mapping.get(value.id);
								if (found == null)
									throw new InternalError('Missing value constructor operand ${value.id}');
								return found;
							}, id -> id);
							expanded.push(new Located(mapped, instruction.provenance));
						}
						expanded;
					}
				default:
					null;
			};
		});
	}

	/** The value a straight-line constructor called with `arguments` arguments returns, defined in its block; null when it cannot be expanded. */
	static function straightLineResult(callee:IrFunction, arguments:Int):Null<IrValue> {
		if (arguments != callee.arguments.length)
			return null;
		var single:IrBlock = callee.blocks[0], terminator = single.terminator;
		if (terminator == null)
			return null;
		var returned:Null<IrValue> = switch terminator.value {
			case Return(value): value;
			default: null;
		};
		if (returned == null)
			return null;
		for (instruction in single.instructions) {
			var value = IrOperands.output(instruction.value);
			if (value != null && value.id == returned.id)
				return returned;
		}
		return null;
	}

	static function firstFreeValue(fn:IrFunction):Int {
		var next = 0;
		for (arg in fn.arguments)
			if (arg.id >= next)
				next = arg.id + 1;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null && out.id >= next)
					next = out.id + 1;
			}
		return next;
	}
}
