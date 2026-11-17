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
	/** Renames the registers of `instructions` in place and returns the types of the registers that remain. */
	public static function run(instructions:Array<HlInstruction>, registerTypes:Array<Int>,
			argumentCount:Int):Array<Int> {
		var count = registerTypes.length;
		if (count <= argumentCount + 1)
			return registerTypes;
		var pinned:Array<Bool> = [for (_ in 0...count) false];
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
		var labels:Map<String, Int> = [];
		for (index in 0...length)
			switch instructions[index] {
				case Label(name):
					labels.set(name, index);
				default:
			}
		var starts:Array<Bool> = [for (_ in 0...length + 1) false];
		starts[0] = true;
		for (index in 0...length) {
			switch instructions[index] {
				case Label(_):
					starts[index] = true;
				default:
			}
			if (HlWriter.jumpTargets(instructions[index]).length > 0 || exits(instructions[index]))
				starts[index + 1] = true;
		}
		var blockStarts:Array<Int> = [], blockOf:Array<Int> = [];
		for (index in 0...length) {
			if (starts[index])
				blockStarts.push(index);
			blockOf.push(blockStarts.length - 1);
		}
		var blocks = blockStarts.length;
		function blockEnd(block:Int):Int
			return block + 1 < blocks ? blockStarts[block + 1] : length;
		var successors:Array<Array<Int>> = [];
		for (block in 0...blocks) {
			var last = blockEnd(block) - 1, next:Array<Int> = [], instruction = instructions[last];
			for (target in HlWriter.jumpTargets(instruction))
				if (next.indexOf(blockOf[labels.get(target)]) < 0)
					next.push(blockOf[labels.get(target)]);
			var falls = switch instruction {
				case Jump(_): false;
				default: !exits(instruction);
			};
			if (falls && block + 1 < blocks)
				next.push(block + 1);
			successors.push(next);
		}
		var handlers = activeHandlers(instructions, blocks, blockStarts, blockEnd, blockOf, labels, successors);
		if (handlers == null)
			return registerTypes;
		// Uses before definitions per block, then the live sets to a fixed point.
		var words = (count + 31) >> 5;
		function bits():Array<Int>
			return [for (_ in 0...words) 0];
		var used:Array<Array<Int>> = [],
			defined:Array<Array<Int>> = [],
			liveIn:Array<Array<Int>> = [],
			liveOut:Array<Array<Int>> = [];
		for (block in 0...blocks) {
			var use = bits(), def = bits();
			for (index in blockStarts[block]...blockEnd(block))
				HlRegisters.each(instructions[index], (register, written) -> {
					var word = register >> 5, bit = 1 << (register & 31);
					if (written)
						def[word] |= bit;
					else if (def[word] & bit == 0)
						use[word] |= bit;
				});
			used.push(use);
			defined.push(def);
			liveIn.push(bits());
			liveOut.push(bits());
		}
		var changed = true;
		while (changed) {
			changed = false;
			var block = blocks;
			while (block-- > 0) {
				var out = liveOut[block], input = liveIn[block], thrown = bits();
				for (successor in successors[block]) {
					var into = liveIn[successor];
					for (word in 0...words)
						out[word] |= into[word];
				}
				// What a handler protecting this block reads is live from its first instruction to its last.
				for (handler in handlers[block]) {
					var into = liveIn[handler];
					for (word in 0...words) {
						out[word] |= into[word];
						thrown[word] |= into[word];
					}
				}
				for (word in 0...words) {
					var next = used[block][word] | (out[word] & ~defined[block][word]) | thrown[word];
					if (next != input[word]) {
						input[word] = next;
						changed = true;
					}
				}
			}
		}
		// The hull of each register's live points in instruction order.
		var first:Array<Int> = [for (_ in 0...count) -1], last:Array<Int> = [for (_ in 0...count) -1];
		function cover(register:Int, position:Int):Void {
			if (first[register] < 0 || position < first[register])
				first[register] = position;
			if (position > last[register])
				last[register] = position;
		}
		for (block in 0...blocks) {
			var start = blockStarts[block], end = blockEnd(block) - 1;
			for (word in 0...words) {
				var input = liveIn[block][word], output = liveOut[block][word];
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
			for (index in start...end + 1)
				HlRegisters.each(instructions[index], (register, _) -> cover(register, index));
		}
		// Linear scan per type: a slot is free again after the last instruction of the register that held it.
		var order = [for (register in 0...count) if (!pinned[register] && first[register] >= 0) register];
		order.sort((a, b) -> first[a] != first[b] ? first[a] - first[b] : a - b);
		var mapping:Array<Int> = [for (_ in 0...count) -1], types:Array<Int> = [];
		for (register in 0...argumentCount) {
			mapping[register] = types.length;
			types.push(registerTypes[register]);
		}
		for (register in argumentCount...count)
			if (pinned[register]) {
				mapping[register] = types.length;
				types.push(registerTypes[register]);
			}
		var freeAt:Array<Int> = [], slotsByType:Map<Int, Array<Int>> = [];
		for (register in order) {
			var type = registerTypes[register], slots = slotsByType.get(type), chosen = -1;
			if (slots == null) {
				slots = [];
				slotsByType.set(type, slots);
			}
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
		for (index in 0...length)
			instructions[index] = HlRegisters.map(instructions[index], register -> mapping[register]);
		return types;
	}

	/**
	 * Per block, the handler blocks of the traps active at any of its instructions: a trap is active from its `Trap` to the
	 * `EndTrap` that closes it, along every path, and its handler is entered with the traps that were active before it. Null when
	 * two paths reach a block with different traps active, which the lowering does not produce; the function is then left as it is.
	 */
	static function activeHandlers(instructions:Array<HlInstruction>, blocks:Int, blockStarts:Array<Int>,
			blockEnd:Int->Int,
			blockOf:Array<Int>, labels:Map<String, Int>, successors:Array<Array<Int>>):Null<Array<Array<Int>>> {
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
						handlerEdge = blockOf[labels.get(target)];
						reach(handlerEdge, stack);
						stack.push(handlerEdge);
					case EndTrap(_, _):
						if (stack.length == 0)
							return null;
						stack.pop();
					default:
				}
			}
			for (successor in successors[block])
				if (successor != handlerEdge)
					reach(successor, stack);
		}
		return consistent ? handlers : null;
	}

	static function exits(instruction:HlInstruction):Bool
		return switch instruction {
			case Return(_), Throw(_), Rethrow(_): true;
			default: false;
		};
}
