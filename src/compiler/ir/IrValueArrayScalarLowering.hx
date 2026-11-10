package compiler.ir;

import compiler.ir.Ir;

/** Expand compiler-generated array element boundaries before scalar replacement on every target. */
class IrValueArrayScalarLowering {
	public static function rewrite(program:IrProgram, element:IrType, expandAll:Bool):Void {
		var helpers:Map<String, IrFunction> = [];
		var suffix = ":" + haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(element));
		for (fn in program.functions)
			if (StringTools.startsWith(fn.name, IrValueArrayElements.PREFIX)
				&& StringTools.endsWith(fn.name, suffix)
				&& (expandAll
					|| StringTools.startsWith(fn.name, IrValueArrayElements.PREFIX + "optional-")
					|| StringTools.startsWith(fn.name, IrValueArrayElements.PREFIX + "iterator-next:")))
				helpers.set(fn.name, fn);
		if (!helpers.keys().hasNext())
			return;
		program.functions = [for (fn in program.functions) rewriteFunction(fn, helpers)];
	}

	static function rewriteFunction(fn:IrFunction, helpers:Map<String, IrFunction>):IrFunction {
		var found = false;
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case Call(_, name, args) if (name != fn.name
						&& helpers.exists(name)
						&& helpers.get(name).arguments.length == args.length):
						found = true;
					default:
				}
			if (found)
				break;
		}
		if (!found)
			return fn;
		var next = 0, nextBlock = 0, blocks:Array<IrBlock> = [], changed = false;
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
				for (input in IrOperands.inputs(located.value))
					if (input.id >= next)
						next = input.id + 1;
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
			if (block.id >= nextBlock)
				nextBlock = block.id + 1;
		}
		var index = 0;
		while (index < blocks.length) {
			var block = blocks[index], position = -1, callee:Null<IrFunction> = null;
			for (i in 0...block.instructions.length)
				switch block.instructions[i].value {
					case Call(_, name, args) if (name != fn.name && helpers.exists(name)):
						var candidate = helpers.get(name);
						if (candidate.arguments.length == args.length) {
							position = i;
							callee = candidate;
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
			changed = true;
			// Scan the cloned body too: push and insert helpers call the element setter.
			index++;
		}
		return changed ? fn.derive(blocks) : fn;
	}
}
