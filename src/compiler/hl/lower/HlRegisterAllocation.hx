package compiler.hl.lower;

import compiler.hl.HlFunction.HlInstruction;

/**
 * Register allocation for a lowered HashLink function. The lowering gives every value a register of its own; here values of the same
 * type whose live ranges do not overlap share one, so a function has about as many registers as values it holds at once.
 *
 * HashLink writes each register's type in the module and a register number above 127 in two bytes, and the JIT gives each register a
 * stack slot: fewer registers make the module smaller and its frames smaller. Release builds only: a debugger shows a variable as
 * the register its assignment wrote, which a later value may then reuse.
 *
 * Live ranges are hulls in instruction order over a block-level liveness analysis, so they cover every point a register is live at;
 * registers are given slots by a linear scan per type. A trap's handler can be entered from any instruction while the trap is
 * active, so every register live into a handler is live throughout each block it protects. Arguments keep their registers, and a
 * register whose address is taken (`Ref`) keeps a slot of its own.
 */
class HlRegisterAllocation {
	// Scratch kept from one function to the next: lowering a program allocates each array once, at the size of its largest function.
	final pinned:Array<Bool> = [];
	/** The instruction of each label id, or -1. */
	final labels:Array<Int> = [];
	final starts:Array<Bool> = [];
	final blockStarts:Array<Int> = [];
	final blockOf:Array<Int> = [];

	/** The successors of block `b` are `successors[successorStart[b] ... successorStart[b + 1] - 1]`. */
	final successorStart:Array<Int> = [];

	final successors:Array<Int> = [];
	final used:Array<Int> = [];
	final defined:Array<Int> = [];
	final liveIn:Array<Int> = [];
	final liveOut:Array<Int> = [];
	final thrown:Array<Int> = [];
	final first:Array<Int> = [];
	final last:Array<Int> = [];
	final mapping:Array<Int> = [];
	final order:Array<Int> = [];
	final freeAt:Array<Int> = [];
	final slotsByType:Map<Int, Array<Int>> = [];

	/** The types whose slots the last function used, emptied for the next; and the types of its slots. */
	final typesWithSlots:Array<Int> = [];

	final types:Array<Int> = [];

	/** Registers by their first instruction, then by number. */
	final byFirst:(Int, Int) -> Int;

	public function new() {
		byFirst = (a, b) -> first[a] != first[b] ? first[a] - first[b] : a - b;
	}

	/** Renames the registers of `instructions` in place and returns the types of the registers that remain. */
	public function run(instructions:Array<HlInstruction>, registerTypes:Array<Int>, argumentCount:Int):Array<Int> {
		var count = registerTypes.length;
		if (count <= argumentCount + 1)
			return registerTypes;
		fillFalse(pinned, count);
		for (index in 0...argumentCount)
			pinned[index] = true;
		for (instruction in instructions)
			switch instruction {
				case Ref(_, source):
					pinned[source] = true;
				default:
			}
		var length = instructions.length;
		// Blocks: a block starts at the first instruction, at a label and after any jump or exit.
		labels.resize(0);
		for (index in 0...length)
			switch instructions[index] {
				case Label(id):
					while (labels.length <= id)
						labels.push(-1);
					labels[id] = index;
				default:
			}
		fillFalse(starts, length + 1);
		starts[0] = true;
		for (index in 0...length) {
			switch instructions[index] {
				case Label(_):
					starts[index] = true;
				default:
			}
			if (HlWriter.jumps(instructions[index]) || exits(instructions[index]))
				starts[index + 1] = true;
		}
		blockStarts.resize(0);
		blockOf.resize(0);
		for (index in 0...length) {
			if (starts[index])
				blockStarts.push(index);
			blockOf.push(blockStarts.length - 1);
		}
		var blocks = blockStarts.length;
		function blockEnd(block:Int):Int
			return block + 1 < blocks ? blockStarts[block + 1] : length;
		successorStart.resize(0);
		successors.resize(0);
		for (block in 0...blocks) {
			var end = blockEnd(block) - 1, instruction = instructions[end];
			successorStart.push(successors.length);
			switch instruction {
				case Switch(_, targets):
					for (target in targets)
						addSuccessor(block, blockOf[labels[target]]);
				default:
					var target = HlWriter.jumpTarget(instruction);
					if (target >= 0)
						addSuccessor(block, blockOf[labels[target]]);
			}
			var falls = switch instruction {
				case Jump(_): false;
				default: !exits(instruction);
			};
			if (falls && block + 1 < blocks)
				successors.push(block + 1);
		}
		successorStart.push(successors.length);
		// Most functions have no trap; only those need the handlers each block is protected by.
		var handlers:Null<Array<Array<Int>>> = null;
		for (instruction in instructions)
			switch instruction {
				case Trap(_, _, _):
					handlers = activeHandlers(instructions, blocks, blockEnd);
					if (handlers == null)
						return registerTypes;
					break;
				default:
			}
		// Uses before definitions per block, then the live sets to a fixed point. Each set is a row of `words` words in one
		// array per kind, block after block.
		var words = (count + 31) >> 5;
		fill(used, blocks * words, 0);
		fill(defined, blocks * words, 0);
		fill(liveIn, blocks * words, 0);
		fill(liveOut, blocks * words, 0);
		fill(thrown, words, 0);
		var row = 0;
		function note(register:Int, written:Bool):Void {
			var word = row + (register >> 5), bit = 1 << (register & 31);
			if (written)
				defined[word] |= bit;
			else if (defined[word] & bit == 0)
				used[word] |= bit;
		}
		for (block in 0...blocks) {
			row = block * words;
			for (index in blockStarts[block]...blockEnd(block))
				HlRegisters.each(instructions[index], note);
		}
		var changed = true;
		while (changed) {
			changed = false;
			var block = blocks;
			while (block-- > 0) {
				var base = block * words;
				for (edge in successorStart[block]...successorStart[block + 1]) {
					var from = successors[edge] * words;
					for (word in 0...words)
						liveOut[base + word] |= liveIn[from + word];
				}
				for (word in 0...words)
					thrown[word] = 0;
				// What a handler protecting this block reads is live from its first instruction to its last.
				if (handlers != null)
					for (handler in handlers[block]) {
						var from = handler * words;
						for (word in 0...words) {
							liveOut[base + word] |= liveIn[from + word];
							thrown[word] |= liveIn[from + word];
						}
					}
				for (word in 0...words) {
					var at = base + word, next = used[at] | (liveOut[at] & ~defined[at]) | thrown[word];
					if (next != liveIn[at]) {
						liveIn[at] = next;
						changed = true;
					}
				}
			}
		}
		// The hull of each register's live points in instruction order.
		fill(first, count, -1);
		fill(last, count, -1);
		function cover(register:Int, position:Int):Void {
			if (first[register] < 0 || position < first[register])
				first[register] = position;
			if (position > last[register])
				last[register] = position;
		}
		var position = 0;
		function coverAt(register:Int, _:Bool):Void
			cover(register, position);
		for (block in 0...blocks) {
			var start = blockStarts[block], end = blockEnd(block) - 1;
			for (word in 0...words) {
				var input = liveIn[block * words + word], output = liveOut[block * words + word];
				if (input == 0 && output == 0)
					continue;
				for (bit in 0...32) {
					var register = (word << 5) + bit;
					if (register >= count)
						break;
					if (input & (1 << bit) != 0)
						cover(register, start);
					if (output & (1 << bit) != 0)
						cover(register, end);
				}
			}
			for (index in start...end + 1) {
				position = index;
				HlRegisters.each(instructions[index], coverAt);
			}
		}
		// Linear scan per type: a slot is free again after the last instruction of the register that held it.
		order.resize(0);
		for (register in 0...count)
			if (!pinned[register] && first[register] >= 0)
				order.push(register);
		order.sort(byFirst);
		fill(mapping, count, -1);
		var types = this.types;
		types.resize(0);
		for (register in 0...argumentCount) {
			mapping[register] = types.length;
			types.push(registerTypes[register]);
		}
		for (register in argumentCount...count)
			if (pinned[register]) {
				mapping[register] = types.length;
				types.push(registerTypes[register]);
			}
		freeAt.resize(0);
		for (type in typesWithSlots)
			slotsByType.get(type).resize(0);
		typesWithSlots.resize(0);
		for (register in order) {
			var type = registerTypes[register], slots = slotsByType.get(type), chosen = -1;
			if (slots == null) {
				slots = [];
				slotsByType.set(type, slots);
			}
			if (slots.length == 0)
				typesWithSlots.push(type);
			for (slot in slots)
				if (freeAt[slot] < first[register]) {
					chosen = slot;
					break;
				}
			if (chosen < 0) {
				chosen = types.length;
				types.push(type);
				freeAt[chosen] = -1;
				slots.push(chosen);
			}
			freeAt[chosen] = last[register];
			mapping[register] = chosen;
		}
		if (types.length == count)
			return registerTypes;
		// A register no instruction names keeps no slot; nothing refers to it.
		function rename(register:Int):Int
			return mapping[register];
		for (index in 0...length)
			instructions[index] = HlRegisters.map(instructions[index], rename);
		return types.copy();
	}

	/** Sets `values` to `count` copies of `value`, keeping its storage. */
	static function fill(values:Array<Int>, count:Int, value:Int):Void {
		values.resize(count);
		for (index in 0...count)
			values[index] = value;
	}

	static function fillFalse(values:Array<Bool>, count:Int):Void {
		values.resize(count);
		for (index in 0...count)
			values[index] = false;
	}

	/** Adds an edge from `block`, whose edges are the last ones added, unless it has it already. */
	function addSuccessor(block:Int, target:Int):Void {
		for (edge in successorStart[block]...successors.length)
			if (successors[edge] == target)
				return;
		successors.push(target);
	}

	/**
	 * Per block, the handler blocks of the traps active at any of its instructions: a trap is active from its `Trap` to the
	 * `EndTrap` that closes it, along every path, and its handler is entered with the traps that were active before it. Null when
	 * two paths reach a block with different traps active, which the lowering does not produce; the function is then left as it is.
	 */
	function activeHandlers(instructions:Array<HlInstruction>, blocks:Int, blockEnd:Int->Int):Null<Array<Array<Int>>> {
		var handlers:Array<Array<Int>> = [for (_ in 0...blocks)[]],
			entry:Array<Null<Array<Int>>> = [for (_ in 0...blocks) null],
			work = [0],
			consistent = true;
		entry[0] = [];
		function reach(block:Int, stack:Array<Int>):Void {
			var known = entry[block];
			if (known == null) {
				entry[block] = stack.copy();
				work.push(block);
			} else if (known.length != stack.length) {
				consistent = false;
			} else
				for (index in 0...stack.length)
					if (known[index] != stack[index])
						consistent = false;
		}
		while (work.length > 0 && consistent) {
			var block = work.pop(), stack = entry[block].copy(), active = handlers[block], handlerEdge = -1;
			for (index in blockStarts[block]...blockEnd(block)) {
				for (handler in stack)
					if (active.indexOf(handler) < 0)
						active.push(handler);
				switch instructions[index] {
					case Trap(_, target, _):
						handlerEdge = blockOf[labels[target]];
						reach(handlerEdge, stack);
						stack.push(handlerEdge);
					case EndTrap(_, _):
						if (stack.length == 0)
							return null;
						stack.pop();
					default:
				}
			}
			for (edge in successorStart[block]...successorStart[block + 1])
				if (successors[edge] != handlerEdge)
					reach(successors[edge], stack);
		}
		return consistent ? handlers : null;
	}

	static function exits(instruction:HlInstruction):Bool
		return switch instruction {
			case Return(_), Throw(_), Rethrow(_): true;
			default: false;
		};
}
