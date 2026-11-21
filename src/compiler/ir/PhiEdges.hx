package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

/**
 * Gives each branch-to-phi edge a block for its parallel copies without mutating cached SSA: `split` on a function, `splitBody`
 * on a body, with tables kept from one body to the next.
 */
class PhiEdges {
	/** The blocks with phis, by id. */
	final phiBlocks = new IrPassScratch.IrValueMarks();

	/** Each edge block made: the block the edge leaves, the one it enters, and its id, in the order they were made. */
	final edgeFrom:Array<Int> = [];

	final edgeTo:Array<Int> = [];
	final edgeIds:Array<Int> = [];

	/** The provenance each edge block's jump takes: its branch's. */
	final edgeProvenances:Array<SourceProvenance> = [];

	/** The id the next edge block takes. */
	var nextId = 0;

	public function new() {}

	/**
	 * `body` with an edge block for each branch or switch edge into a block with phis, as `split` does: the same body when it has
	 * none, else a copy (made with `builder`) whose edge blocks follow its own, numbered from past its largest block id.
	 */
	public function splitBody(body:IrBody, builder:IrBodyBuilder):IrBody {
		phiBlocks.clear();
		nextId = 0;
		for (block in 0...body.blockCount()) {
			var id = body.blockId(block);
			if (id >= nextId)
				nextId = id + 1;
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Phi) {
					phiBlocks.add(id);
					break;
				}
				row = body.nextRow(row);
			}
		}
		var splits = false;
		for (block in 0...body.blockCount()) {
			var terminator = body.terminatorRow(block);
			if (terminator < 0)
				continue;
			var opcode = body.opcode(terminator);
			if (opcode == IrOpcode.Branch || opcode == IrOpcode.Switch)
				for (index in 0...body.successorCount(terminator))
					if (phiBlocks.has(body.successor(terminator, index)))
						splits = true;
			if (splits)
				break;
		}
		if (!splits)
			return body;
		var result = body.thaw(builder);
		edgeFrom.resize(0);
		edgeTo.resize(0);
		edgeIds.resize(0);
		edgeProvenances.resize(0);
		for (block in 0...result.blockCount()) {
			var terminator = result.terminatorRow(block);
			if (terminator < 0)
				continue;
			var from = result.blockId(block), provenance = result.provenance(terminator);
			switch result.opcode(terminator) {
				case IrOpcode.Branch:
					for (index in 0...2) {
						var target = result.auxInt(terminator, index);
						if (phiBlocks.has(target))
							result.setAuxInt(terminator, index, edgeBlock(from, target, provenance));
					}
				case IrOpcode.Switch:
					// The targets, then the default, as `split` redirects them.
					var count = result.auxInt(terminator, 1);
					for (index in 0...count) {
						var target = result.auxInt(terminator, 2 + index);
						if (phiBlocks.has(target))
							result.setAuxInt(terminator, 2 + index, edgeBlock(from, target, provenance));
					}
					var otherwise = result.auxInt(terminator, 0);
					if (phiBlocks.has(otherwise))
						result.setAuxInt(terminator, 0, edgeBlock(from, otherwise, provenance));
				default:
			}
		}
		for (block in 0...result.blockCount()) {
			var to = result.blockId(block), row = result.firstRow(block);
			while (row >= 0) {
				if (result.opcode(row) == IrOpcode.Phi)
					for (input in 0...result.operandCount(row)) {
						var edge = edgeOf(result.auxInt(row, input), to);
						if (edge >= 0)
							result.setAuxInt(row, input, edge);
					}
				row = result.nextRow(row);
			}
		}
		for (index in 0...edgeIds.length) {
			var at = result.blockCount();
			result.addBlock(at, edgeIds[index]);
			result.beginRow();
			result.linkAfter(at, -1,
				result.endRow(IrOpcode.Jump, IrValueId.of(-1), edgeTo[index], edgeProvenances[index]));
		}
		return result;
	}

	/** The edge block from `from` to `to`, made when there is none yet. */
	function edgeBlock(from:Int, to:Int, provenance:SourceProvenance):Int {
		var known = edgeOf(from, to);
		if (known >= 0)
			return known;
		var id = nextId++;
		edgeFrom.push(from);
		edgeTo.push(to);
		edgeIds.push(id);
		edgeProvenances.push(provenance);
		return id;
	}

	function edgeOf(from:Int, to:Int):Int {
		for (index in 0...edgeIds.length)
			if (edgeFrom[index] == from && edgeTo[index] == to)
				return edgeIds[index];
		return -1;
	}

	/** Lets go of the provenances of the body last split. */
	public function release():Void
		edgeProvenances.resize(0);

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
		// Only a branch into a block with phis gets an edge block: without one, nothing is copied.
		var splits = false;
		for (block in fn.blocks)
			if (block.terminator != null)
				switch block.terminator.value {
					case Branch(_, yes, no) if (phiBlocks.exists(yes) || phiBlocks.exists(no)):
						splits = true;
						break;
					case Switch(_, targets, otherwise) if (phiBlocks.exists(otherwise)
						|| Lambda.exists(targets, target -> phiBlocks.exists(target))):
						splits = true;
						break;
					default:
				}
		if (!splits)
			return fn;
		var edges:Map<String, Int> = [],
			result:Array<IrBlock> = [],
			added:Array<IrBlock> = [];
		// One edge block per predecessor and phi block: the switch values that select the same block share it.
		function redirect(block:IrBlock, target:Int, provenance:SourceProvenance):Int {
			if (!phiBlocks.exists(target))
				return target;
			var key = block.id + ":" + target;
			if (!edges.exists(key)) {
				var edge = new IrBlock(nextId++);
				edge.terminator = new Located(Jump(target), provenance);
				added.push(edge);
				edges.set(key, edge.id);
			}
			return edgeId(edges, key);
		}
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id), terminator = block.terminator;
			copy.terminator = terminator;
			if (terminator != null)
				switch terminator.value {
					case Branch(condition, yes, no):
						var targets:Array<Int> = [yes, no],
							redirected:Array<Int> = [];
						for (target in targets) {
							if (phiBlocks.exists(target)) {
								var key = block.id + ":" + target;
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
						copy.terminator = new Located(Branch(condition, redirected[0], redirected[1]),
							terminator.provenance);
					case Switch(value, targets, otherwise):
						copy.terminator = new Located(Switch(value,
							[for (target in targets) redirect(block, target, terminator.provenance)],
							redirect(block, otherwise, terminator.provenance)), terminator.provenance);
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
							phiInputs.push({
								block: edges.exists(key) ? edgeId(edges, key) : input.block,
								value: input.value
							});
						}
						copy.instructions.push(new Located(Phi(output, phiInputs), instruction.provenance));
					default:
						copy.instructions.push(instruction);
				}
		}
		return fn.withBlocks(result.concat(added));
	}

	static function edgeId(edges:Map<String, Int>, key:String):Int {
		if (!edges.exists(key))
			throw new InternalError('Missing phi edge $key');
		return edges.get(key);
	}
}
