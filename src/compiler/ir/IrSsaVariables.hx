package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceOrigin;

/** A phi made while a function is built; placed at the start of its block when the function is finished. */
class IrPendingPhi {
	public final block:Int;
	public final variable:Int;
	public final output:IrValue;
	public final inputs:Array<IrPhiInput> = [];

	/** Set when the variable is replaced (`IrIteratorReplacement`): the phi is not placed. */
	public var removed = false;

	public function new(block, variable, output) {
		this.block = block;
		this.variable = variable;
		this.output = output;
	}
}

/**
 * Local variables of one function in SSA form, by the algorithm of Braun et al., "Simple and Efficient Construction of
 * Static Single Assignment Form" (CC 2013): a write makes a value the variable's current one in its block; a read finds
 * it in the block or through the block's predecessors, making a phi where they meet. A block is sealed once all its
 * predecessors are known; a read in a block that is not makes an incomplete phi, completed when the block is sealed.
 * Trivial phis (all inputs one value, or the phi itself) are replaced by that value, and every use is rewritten when the
 * function is finished. Lookups are iterative: generated functions can chain thousands of blocks. The tables are kept in
 * `IrSsaScratch` and reused from function to function.
 */
class IrSsaVariables {
	final scratch:IrSsaScratch;

	/** The next value id; the builder that owns these variables allocates from the same counter. */
	public var nextValue = 0;

	var variableCount = 0;
	var blockCount = 0;

	final phis:Array<IrPendingPhi> = [];

	/** Phis read while their block was unsealed, completed when it is sealed. */
	final incomplete:Array<IrPendingPhi> = [];

	/** Whether a phi already handed out was replaced, so its uses must be rewritten. */
	var exposedReplaced = false;

	/** The declared type of each local by name, which a phi of it takes; a local not in it has the type it was first used with. */
	final localTypes:Null<Map<String, IrType>>;

	public function new(scratch:IrSsaScratch, ?localTypes:Map<String, IrType>) {
		this.scratch = scratch;
		this.localTypes = localTypes;
		scratch.reset();
	}

	/** The variable called `name`, numbered the first time it is seen. */
	public function variable(name:String, type:IrType):Int {
		var slots = scratch.slots, known = slots.get(name);
		if (known != null)
			return known;
		var id = variableCount++;
		slots.set(name, id);
		scratch.variableNames[id] = name;
		scratch.variableTypes[id] = type;
		scratch.undefinedValues[id] = null;
		return id;
	}

	public inline function variableName(variable:Int):String
		return scratch.variableNames[variable];

	public inline function variableType(variable:Int):IrType
		return scratch.variableTypes[variable];

	/** A new value with no local behind it. */
	public function newValue(type:IrType):IrValue {
		var id = nextValue++;
		return new IrValue(id, scratch.valueName(id), type);
	}

	/** Whether `block` defines `variable` itself (or a lookup through it already recorded the value it ends with). */
	public inline function definesIn(block:Int, variable:Int):Bool
		return scratch.definitions.get(block, variable) != null;

	public inline function pendingPhis():Array<IrPendingPhi>
		return phis;

	public inline function isRemoved(phi:IrPendingPhi):Bool
		return phi.removed;

	public function removePhisOf(variable:Int):Void
		for (phi in phis)
			if (phi.variable == variable)
				phi.removed = true;

	/** Adds block `id`; `sealed` when no predecessor will be added after the first read in it. */
	public function addBlock(id:Int, sealed:Bool):Void {
		if (id != blockCount)
			throw new InternalError('SSA block $id added out of order');
		blockCount++;
		scratch.sealed[id] = sealed;
		scratch.selected[id] = false;
		scratch.lookedThrough[id] = false;
		scratch.predecessorCounts[id] = 0;
		scratch.firstPredecessors[id] = -1;
		scratch.morePredecessors[id] = null;
	}

	public inline function isSealed(block:Int):Bool
		return scratch.sealed[block];

	/**
	 * Records the edge `from` to `to`. An edge into a sealed block is only sound while no read has looked through that
	 * block's predecessors; after that, the block must have been made open.
	 */
	public function addEdge(from:Int, to:Int):Void {
		if (scratch.sealed[to] && scratch.selected[to] && scratch.lookedThrough[to])
			throw new InternalError('Edge from SSA block $from into block $to, which was sealed and read through');
		var count = scratch.predecessorCounts[to];
		if (count == 0)
			scratch.firstPredecessors[to] = from;
		else {
			var more = scratch.morePredecessors[to];
			if (more == null) {
				more = [];
				scratch.morePredecessors[to] = more;
			}
			more.push(from);
		}
		scratch.predecessorCounts[to] = count + 1;
		scratch.edgeFrom.push(from);
		scratch.edgeTo.push(to);
	}

	/** Marks `block` as the one being emitted; a block created sealed is sealed from now on. */
	public inline function select(block:Int):Void
		scratch.selected[block] = true;

	inline function predecessor(block:Int, index:Int):Int
		return index == 0 ? scratch.firstPredecessors[block] : scratch.morePredecessors[block][index - 1];

	public function write(variable:Int, block:Int, value:IrValue):Void
		scratch.definitions.set(block, variable, value);

	/** The value of `variable` at the current end of `block`. */
	public function read(variable:Int, block:Int):IrValue {
		var known = scratch.definitions.get(block, variable),
			value = known != null ? find(known) : readThroughPredecessors(variable, block);
		if (value.id < 0) {
			scratch.undefinedReads.push(block);
			scratch.undefinedReads.push(variable);
		}
		return value;
	}

	static inline final SINGLE = 1;
	static inline final MULTIPLE = 2;

	function readThroughPredecessors(variable:Int, start:Int):IrValue {
		var stack = scratch.lookupBlocks,
			states = scratch.lookupStates,
			indices = scratch.lookupIndices,
			frames = scratch.lookupPhis,
			depth = 0,
			result:IrValue = null;
		push(stack, states, 0, start);
		depth = 1;
		while (depth > 0) {
			var top = depth - 1, block = stack[top];
			if (result == null) {
				// A new frame: the value is in the block, the block is unsealed, or it comes from its predecessors.
				var known = top == 0 ? null : scratch.definitions.get(block, variable);
				if (known != null) {
					result = find(known);
					depth--;
					continue;
				}
				scratch.lookedThrough[block] = true;
				if (!scratch.sealed[block]) {
					var phi = newPhi(block, variable);
					incomplete.push(phi);
					write(variable, block, phi.output);
					result = phi.output;
					depth--;
					continue;
				}
				var count = scratch.predecessorCounts[block];
				if (count == 0) {
					result = undefined(variable);
					write(variable, block, result);
					depth--;
					continue;
				}
				if (count == 1) {
					states[top] = SINGLE;
				} else {
					var phi = newPhi(block, variable);
					write(variable, block, phi.output);
					states[top] = MULTIPLE;
					frames[top] = phi;
					indices[top] = 0;
				}
				push(stack, states, depth, predecessor(block, 0));
				depth++;
				continue;
			}
			// A value came back from the frame above.
			if (states[top] == SINGLE) {
				write(variable, block, result);
				depth--;
				continue;
			}
			var phi = frames[top], index = indices[top];
			if (phi == null)
				throw new InternalError("SSA lookup lost its phi");
			phi.inputs.push({block: predecessor(block, index), value: result});
			index++;
			if (index < scratch.predecessorCounts[block]) {
				indices[top] = index;
				result = null;
				push(stack, states, depth, predecessor(block, index));
				depth++;
				continue;
			}
			frames[top] = null;
			result = removeIfTrivial(phi, false);
			write(variable, block, result);
			depth--;
		}
		return result;
	}

	function push(stack:Array<Int>, states:Array<Int>, depth:Int, block:Int):Void {
		if (depth == stack.length) {
			stack.push(block);
			states.push(0);
			scratch.lookupIndices.push(0);
			scratch.lookupPhis.push(null);
		} else {
			stack[depth] = block;
			states[depth] = 0;
		}
	}

	function newPhi(block:Int, variable:Int):IrPendingPhi {
		var name = scratch.variableNames[variable], declared = localTypes == null ? null : localTypes.get(name);
		var phi = new IrPendingPhi(block, variable, new IrValue(nextValue++, name,
			declared == null ? scratch.variableTypes[variable] : declared));
		phis.push(phi);
		return phi;
	}

	/** The value standing for `variable` where it has no definition: on a path from a block nothing jumps to. */
	function undefined(variable:Int):IrValue {
		var value = scratch.undefinedValues[variable];
		if (value == null) {
			value = new IrValue(-1 - variable, scratch.variableNames[variable], scratch.variableTypes[variable]);
			scratch.undefinedValues[variable] = value;
		}
		return value;
	}

	/** `value` after the replacements made so far. */
	public function find(value:IrValue):IrValue {
		var replacements = scratch.replacements;
		while (true) {
			var id = value.id;
			if (id < 0 || id >= replacements.length)
				return value;
			var next = replacements[id];
			if (next == null)
				return value;
			value = next;
		}
	}

	/** The phi's only other input, which then replaces it; or the phi itself. */
	function removeIfTrivial(phi:IrPendingPhi, exposed:Bool):IrValue {
		var same:Null<IrValue> = null, output = phi.output;
		for (input in phi.inputs) {
			var value = find(input.value);
			if (value == output || value == same)
				continue;
			if (same != null)
				return output;
			same = value;
		}
		if (same == null)
			return output; // only itself: in a block no path reaches, removed with it
		replace(output, same);
		if (exposed)
			exposedReplaced = true;
		return same;
	}

	/** Makes every use of `value` a use of `by`; the uses are rewritten when the function is finished. */
	public function replaceUses(value:IrValue, by:IrValue):Void {
		replace(value, by);
		exposedReplaced = true;
	}

	function replace(value:IrValue, by:IrValue):Void {
		var replacements = scratch.replacements;
		while (replacements.length <= value.id)
			replacements.push(null);
		replacements[value.id] = by;
	}

	/** Completes the incomplete phis of `block`, now that all its predecessors are known. */
	public function seal(block:Int):Void {
		if (scratch.sealed[block])
			return;
		scratch.sealed[block] = true;
		var index = 0;
		while (index < incomplete.length) {
			var phi = incomplete[index];
			if (phi.block != block) {
				index++;
				continue;
			}
			incomplete[index] = incomplete[incomplete.length - 1];
			incomplete.pop();
			complete(phi);
		}
	}

	/**
	 * The value of `variable` on entry to `block`, from its predecessors, for a block that defines the variable itself and
	 * read it before that. The block's own definition stays the value it ends with.
	 */
	public function readAtEntry(variable:Int, block:Int):IrValue {
		var count = scratch.predecessorCounts[block];
		if (count == 0)
			return undefined(variable);
		if (count == 1)
			return read(variable, predecessor(block, 0));
		var phi = newPhi(block, variable);
		for (index in 0...count) {
			var from = predecessor(block, index);
			phi.inputs.push({block: from, value: read(variable, from)});
		}
		return removeIfTrivial(phi, true);
	}

	function complete(phi:IrPendingPhi):Void {
		var count = scratch.predecessorCounts[phi.block];
		for (index in 0...count) {
			var from = predecessor(phi.block, index);
			phi.inputs.push({block: from, value: read(phi.variable, from)});
		}
		removeIfTrivial(phi, true);
	}

	/** Seals every block still open: every predecessor is known once the function is built. */
	public function sealAll():Void {
		for (block in 0...blockCount)
			if (!scratch.sealed[block])
				seal(block);
		while (incomplete.length > 0) {
			var phi = incomplete.pop();
			complete(phi);
		}
	}

	/**
	 * Seals every block, drops what unreachable blocks contributed, places the remaining phis at the start of their blocks
	 * and rewrites the uses of replaced phis. Unreachable blocks are emptied. Calls `bindPhi` for each phi placed.
	 */
	public function finish(blocks:Array<IrBlock>, bindPhi:(variable:Int, value:IrValue) -> Void):Void {
		sealAll();
		var reachable = reachableBlocks();
		// Inputs from blocks no path reaches are dropped; a phi left with one value is then trivial.
		for (phi in phis)
			if (!phi.removed && reachable[phi.block] && find(phi.output) == phi.output) {
				var kept = 0, inputs = phi.inputs;
				for (input in inputs)
					if (reachable[input.block])
						inputs[kept++] = input;
				if (kept != inputs.length)
					inputs.resize(kept);
			}
		// Replacing a phi can make another trivial: repeat until none is.
		var replacedNow = true;
		while (replacedNow) {
			replacedNow = false;
			for (phi in phis)
				if (!phi.removed && reachable[phi.block] && find(phi.output) == phi.output
					&& removeIfTrivial(phi, true) != phi.output)
					replacedNow = true;
		}
		var reads = scratch.undefinedReads, index = 0;
		while (index < reads.length) {
			if (reachable[reads[index]])
				throw new InternalError('Local "${scratch.variableNames[reads[index + 1]]}" used before definition');
			index += 2;
		}
		for (phi in phis)
			if (!phi.removed && reachable[phi.block] && find(phi.output).id < 0)
				throw new InternalError('Local "${scratch.variableNames[phi.variable]}" used before definition');
		var rewrite = exposedReplaced;
		for (block in blocks)
			if (!reachable[block.id]) {
				block.instructions.resize(0);
				block.terminator = null;
			} else if (rewrite)
				rewriteBlock(block);
		placePhis(blocks, reachable, bindPhi);
	}

	static function sameBlock(id:Int):Int
		return id;

	function rewriteBlock(block:IrBlock):Void {
		var instructions = block.instructions, use = find;
		for (position in 0...instructions.length) {
			var located = instructions[position], instruction = located.value, stale = false;
			for (operand in 0...IrOperands.count(instruction))
				if (find(IrOperands.at(instruction, operand)) != IrOperands.at(instruction, operand)) {
					stale = true;
					break;
				}
			if (stale)
				instructions[position] = new Located(IrInliner.remap(instruction, use, sameBlock), located.provenance);
		}
		var terminator = block.terminator;
		if (terminator != null) {
			var updated = switch terminator.value {
				case Return(value) if (find(value) != value): Return(find(value));
				case Throw(value) if (find(value) != value): Throw(find(value));
				case Rethrow(value) if (find(value) != value): Rethrow(find(value));
				case Branch(condition, yes, no) if (find(condition) != condition): Branch(find(condition), yes, no);
				case Switch(value, targets, otherwise) if (find(value) != value): Switch(find(value), targets,
					otherwise);
				default: null;
			};
			if (updated != null)
				block.terminator = new Located(updated, terminator.provenance);
		}
	}

	function placePhis(blocks:Array<IrBlock>, reachable:Array<Bool>,
			bindPhi:(variable:Int, value:IrValue) -> Void):Void {
		var placed = scratch.placed;
		placed.resize(0);
		for (phi in phis)
			if (!phi.removed && reachable[phi.block] && find(phi.output) == phi.output)
				placed.push(phi);
		if (placed.length == 0)
			return;
		// Phis go to their blocks in the order they were made, so a block's phis are contiguous after a stable sort.
		placed.sort((a, b) -> a.block - b.block);
		var index = 0;
		while (index < placed.length) {
			var block = blocks[placed[index].block], end = index;
			while (end < placed.length && placed[end].block == block.id)
				end++;
			var provenance = phiProvenance(block), heads:Array<Located<IrInstruction>> = [];
			for (at in index...end) {
				var phi = placed[at];
				var inputs:Array<IrPhiInput> = [for (input in phi.inputs) {
					var value = find(input.value);
					if (value.id < 0)
						throw new InternalError('Local "${scratch.variableNames[phi.variable]}" used before definition');
					{
						block:input.block, value:value
					};
				}];
				heads.push(new Located(Phi(phi.output, inputs), provenance));
				bindPhi(phi.variable, phi.output);
			}
			var instructions = block.instructions;
			for (at in 0...heads.length)
				instructions.insert(at, heads[at]);
			index = end;
		}
		placed.resize(0);
	}

	static function phiProvenance(block:IrBlock):SourceProvenance {
		var anchor:Null<compiler.ir.SourceProvenance.SourceLocation> = null;
		if (block.instructions.length > 0)
			anchor = block.instructions[0].provenance.location;
		else if (block.terminator != null)
			anchor = block.terminator.provenance.location;
		return new SourceProvenance(anchor, SourceOrigin.CompilerGenerated("ssa-phi"));
	}

	/** The blocks a path from the entry reaches, over the recorded edges (jumps and handler entries). */
	function reachableBlocks():Array<Bool> {
		var reachable = scratch.reachable,
			starts = scratch.edgeStarts,
			targets = scratch.edgeTargets,
			from = scratch.edgeFrom,
			to = scratch.edgeTo,
			work = scratch.reachWork;
		reachable.resize(blockCount);
		starts.resize(blockCount + 1);
		for (index in 0...blockCount + 1)
			starts[index] = 0;
		for (index in 0...blockCount)
			reachable[index] = false;
		for (edge in 0...from.length)
			starts[from[edge] + 1]++;
		for (index in 0...blockCount)
			starts[index + 1] += starts[index];
		targets.resize(from.length);
		var fill = scratch.reachFill;
		fill.resize(blockCount);
		for (index in 0...blockCount)
			fill[index] = starts[index];
		for (edge in 0...from.length)
			targets[fill[from[edge]]++] = to[edge];
		work.resize(0);
		if (blockCount > 0) {
			reachable[0] = true;
			work.push(0);
		}
		while (work.length > 0) {
			var block = work.pop();
			for (edge in starts[block]...starts[block + 1]) {
				var target = targets[edge];
				if (!reachable[target]) {
					reachable[target] = true;
					work.push(target);
				}
			}
		}
		return reachable;
	}

	/** Whether `value` stands for a variable with no definition on some path. */
	public static inline function isUndefined(value:IrValue):Bool
		return value.id < 0;
}

/** The tables of `IrSsaVariables`, kept from one function to the next so building a function allocates little else. */
class IrSsaScratch {
	public final slots:Map<String, Int> = [];
	public final variableNames:Array<String> = [];
	public final variableTypes:Array<IrType> = [];
	public final undefinedValues:Array<Null<IrValue>> = [];
	public final definitions = new IrBlockVariableTable();
	public final sealed:Array<Bool> = [];
	public final lookedThrough:Array<Bool> = [];
	public final selected:Array<Bool> = [];
	public final predecessorCounts:Array<Int> = [];
	public final firstPredecessors:Array<Int> = [];
	public final morePredecessors:Array<Null<Array<Int>>> = [];
	public final edgeFrom:Array<Int> = [];
	public final edgeTo:Array<Int> = [];
	public final edgeStarts:Array<Int> = [];
	public final edgeTargets:Array<Int> = [];
	public final reachable:Array<Bool> = [];
	public final reachWork:Array<Int> = [];
	public final reachFill:Array<Int> = [];
	public final replacements:Array<Null<IrValue>> = [];
	public final lookupBlocks:Array<Int> = [];
	public final lookupStates:Array<Int> = [];
	public final lookupIndices:Array<Int> = [];
	public final lookupPhis:Array<Null<IrPendingPhi>> = [];
	public final placed:Array<IrPendingPhi> = [];
	final valueNames:Array<String> = [];

	public function new() {}

	/** `v<id>`, the name of a value with no local behind it, made once per id. */
	public function valueName(id:Int):String {
		while (valueNames.length <= id)
			valueNames.push("v" + valueNames.length);
		return valueNames[id];
	}

	public function reset():Void {
		slots.clear();
		definitions.clear();
		edgeFrom.resize(0);
		edgeTo.resize(0);
		replacements.resize(0);
		undefinedReads.resize(0);
	}

	public final undefinedReads:Array<Int> = [];
}

/** A map from a (block, variable) pair to a value: open addressing over parallel arrays, cleared at once by a stamp. */
class IrBlockVariableTable {
	var blocks:Array<Int> = [];
	var variables:Array<Int> = [];
	var values:Array<Null<IrValue>> = [];
	var stamps:Array<Int> = [];
	var generation = 1;
	var count = 0;
	var capacity = 0;

	public function new() {}

	public function clear():Void {
		generation++;
		count = 0;
	}

	static inline function slot(block:Int, variable:Int, mask:Int):Int {
		var hash = block * 0x01000193 ^ variable * 0x5bd1e995;
		return (hash ^ (hash >>> 15)) & mask;
	}

	public function get(block:Int, variable:Int):Null<IrValue> {
		if (capacity == 0)
			return null;
		var mask = capacity - 1, index = slot(block, variable, mask);
		while (stamps[index] == generation) {
			if (blocks[index] == block && variables[index] == variable)
				return values[index];
			index = (index + 1) & mask;
		}
		return null;
	}

	public function set(block:Int, variable:Int, value:IrValue):Void {
		if ((count + 1) * 2 > capacity)
			grow();
		var mask = capacity - 1, index = slot(block, variable, mask);
		while (stamps[index] == generation) {
			if (blocks[index] == block && variables[index] == variable) {
				values[index] = value;
				return;
			}
			index = (index + 1) & mask;
		}
		stamps[index] = generation;
		blocks[index] = block;
		variables[index] = variable;
		values[index] = value;
		count++;
	}

	function grow():Void {
		var oldBlocks = blocks,
			oldVariables = variables,
			oldValues = values,
			oldStamps = stamps,
			oldCapacity = capacity;
		capacity = capacity == 0 ? 256 : capacity * 2;
		blocks = [for (_ in 0...capacity) 0];
		variables = [for (_ in 0...capacity) 0];
		values = [for (_ in 0...capacity) null];
		stamps = [for (_ in 0...capacity) 0];
		count = 0;
		for (index in 0...oldCapacity)
			if (oldStamps[index] == generation)
				set(oldBlocks[index], oldVariables[index], oldValues[index]);
	}
}
