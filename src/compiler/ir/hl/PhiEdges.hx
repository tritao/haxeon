package compiler.ir.hl;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Gives each branch-to-phi edge a block for its parallel copies without mutating cached SSA. */
class PhiEdges {
	public static function split(fn:IrFunction):IrFunction {
		var phiBlocks:Map<Int, Bool> = [], nextId = 0;
		for (block in fn.blocks) {
			if (block.id >= nextId)
				nextId = block.id + 1;
			for (instruction in block.instructions)
				switch instruction.value {
					case Phi(_, _):
						phiBlocks.set(block.id, true);
					default:
				}
		}
		var edges:Map<String, Int> = [],
			result:Array<IrBlock> = [],
			added:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id), terminator = block.terminator;
			copy.terminator = terminator;
			if (terminator != null)
				switch terminator.value {
					case Branch(condition, yes, no):
						var targets:Array<Int> = [yes, no],
							redirected:Array<Int> = [];
						for (target in targets) {
							var key = block.id + ":" + target;
							if (phiBlocks.exists(target)) {
								if (!edges.exists(key)) {
									var edge = new IrBlock(nextId++);
									edge.terminator = new Located(Jump(target), terminator.provenance);
									added.push(edge);
									edges.set(key, edge.id);
								}
								redirected.push(edgeId(edges, key));
							} else
								redirected.push(target);
						}
						copy.terminator = new Located(Branch(condition, redirected[0], redirected[1]), terminator.provenance);
					default:
				}
			result.push(copy);
		}
		if (added.length == 0)
			return fn;
		for (index in 0...fn.blocks.length) {
			var block = fn.blocks[index], copy = result[index];
			for (instruction in block.instructions)
				switch instruction.value {
					case Phi(output, inputs):
						var phiInputs:Array<IrPhiInput> = [];
						for (input in inputs) {
							var key = input.block + ":" + block.id;
							phiInputs.push({block: edges.exists(key) ? edgeId(edges, key) : input.block, value: input.value});
						}
						copy.instructions.push(new Located(Phi(output, phiInputs), instruction.provenance));
					default:
						copy.instructions.push(instruction);
				}
		}
		return new IrFunction(fn.name, fn.arguments, fn.result, result.concat(added), fn.debugBindings);
	}

	static function edgeId(edges:Map<String, Int>, key:String):Int {
		if (!edges.exists(key))
			throw 'Missing phi edge $key';
		return edges.get(key);
	}
}
