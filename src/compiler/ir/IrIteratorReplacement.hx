package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** A store of an iterator into a local, at `index` among the instructions of `block` when it was made. */
typedef IrIteratorStore = {
	final variable:Int;
	final value:IrValue;
	final block:Int;
	final index:Int;
}

/**
 * Replaces a local array iterator with an array and a position, while its function is finished (`IrLocalsBuilder.finish`).
 *
 * `var it = values.iterator(); while (it.hasNext()) use(it.next());` allocated an iterator object and made two runtime
 * calls per element. When a local holds only iterators created for it, each stored into it once and into no other local,
 * and its values feed nothing but `hasNext` and `next`, nothing else can observe the object: `hasNext` becomes
 * `position < array.length`, `next` becomes `array[position]` followed by `position + 1`, and the array and position are
 * locals of their own, placed in SSA by the same variables (reads before a block's own definition are resolved once every
 * block is rewritten).
 *
 * The array length and element are read at every call, as the runtime iterator does, so changing the array during the
 * loop behaves the same. Only element types whose raw array read is exactly what the iterator does are handled, and
 * functions with exception handling are skipped: a handler sees the locals as they were when its try began, which source
 * locals get around by becoming cells, and the position would not.
 */
class IrIteratorReplacement {
	final blocks:Array<IrBlock>;
	final variables:IrSsaVariables;
	final stores:Array<IrIteratorStore>;

	/** Reads made before their block defines the variable: the value at the block's entry, resolved after the rewrite. */
	final entryReads:Array<{block:Int, variable:Int, placeholder:IrValue}> = [];

	final entryReadOf:Map<String, IrValue> = [];

	function new(blocks, variables, stores) {
		this.blocks = blocks;
		this.variables = variables;
		this.stores = stores;
	}

	/** The variables replaced, whose stores and phis are gone. */
	public static function run(blocks:Array<IrBlock>, variables:IrSsaVariables, stores:Array<IrIteratorStore>,
			isArgument:Int->Bool):Array<Int> {
		if (stores.length == 0)
			return [];
		return new IrIteratorReplacement(blocks, variables, stores).replace(isArgument);
	}

	function replace(isArgument:Int->Bool):Array<Int> {
		// What each iterator creation reads, and whether a function has a try.
		var created:Map<Int, {array:IrValue, provenance:SourceProvenance}> = [];
		for (block in blocks)
			for (located in block.instructions)
				switch located.value {
					case IteratorNew(output, array):
						created.set(output.id, {array: array, provenance: located.provenance});
					case BeginTry(_, _, _):
						return [];
					default:
				}
		// Candidates: locals of a replaceable iterator type whose every store is a creation stored nowhere else.
		var candidates:Map<Int, IrType> = [], storeCounts:Map<Int, Int> = [];
		for (store in stores)
			storeCounts.set(store.value.id, (storeCounts.get(store.value.id) ?? 0) + 1);
		for (store in stores) {
			var element = switch variables.variableType(store.variable) {
				case Iterator(element) if (replaceable(element)): element;
				default: null;
			};
			if (element != null && !isArgument(store.variable))
				candidates.set(store.variable, element);
		}
		var rejected:Map<Int, Bool> = [];
		for (store in stores)
			if (!created.exists(store.value.id) || storeCounts.get(store.value.id) != 1)
				rejected.set(store.variable, true);
		// The values of each candidate: its creations and its phis.
		var owner:Map<Int, Int> = [];
		for (store in stores)
			if (candidates.exists(store.variable))
				owner.set(store.value.id, store.variable);
		for (phi in variables.pendingPhis())
			if (candidates.exists(phi.variable) && !variables.isRemoved(phi))
				owner.set(phi.output.id, phi.variable);
		inline function reject(value:IrValue):Void {
			var variable = owner.get(variables.find(value).id);
			if (variable != null)
				rejected.set(variable, true);
		}
		// A phi of a candidate merges only its values; a phi of any other local holding one copies it.
		for (phi in variables.pendingPhis()) {
			if (variables.isRemoved(phi))
				continue;
			for (input in phi.inputs) {
				var value = variables.find(input.value), from = owner.get(value.id);
				if (from == null) {
					if (owner.get(phi.output.id) != null)
						rejected.set(phi.variable, true); // an argument or an undefined value reaches it
				} else if (from != phi.variable) {
					rejected.set(from, true);
					rejected.set(phi.variable, true);
				}
			}
		}
		// A candidate's values feed nothing but hasNext and next with the element type.
		for (block in blocks) {
			for (located in block.instructions)
				switch located.value {
					case IteratorNew(_, _):
					case IteratorHasNext(_, _):
					case IteratorNext(output, iterator):
						var variable = owner.get(variables.find(iterator).id);
						if (variable != null && !IrTypeIdentity.same(output.type, candidates.get(variable)))
							rejected.set(variable, true);
					default:
						var instruction = located.value;
						for (operand in 0...IrOperands.count(instruction))
							reject(IrOperands.at(instruction, operand));
				}
			var terminator = block.terminator;
			if (terminator != null)
				switch terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _), Switch(value, _, _):
						reject(value);
					case Jump(_), Unreachable:
				}
		}
		var replaced:Array<Int> = [];
		for (variable => _ in candidates)
			if (!rejected.exists(variable))
				replaced.push(variable);
		if (replaced.length == 0)
			return [];
		replaced.sort((a, b) -> a - b);
		var arrays:Map<Int, Int> = [], positions:Map<Int, Int> = [];
		for (variable in replaced) {
			var name = variables.variableName(variable), element = candidates.get(variable);
			arrays.set(variable, variables.variable(name + "$iterator-array", Array(element)));
			positions.set(variable, variables.variable(name + "$iterator-position", I32));
		}
		var storesAt:Map<Int, Array<IrIteratorStore>> = [];
		for (store in stores)
			if (arrays.exists(store.variable)) {
				var list = storesAt.get(store.block);
				if (list == null) {
					list = [];
					storesAt.set(store.block, list);
				}
				list.push(store);
			}
		for (block in blocks)
			rewriteBlock(block, storesAt.get(block.id), owner, arrays, positions, created);
		// Whether a block defines the variable itself is known now, before resolving reads adds what flows through it.
		var ownDefinition = [for (read in entryReads) variables.definesIn(read.block, read.variable)];
		for (index in 0...entryReads.length) {
			var read = entryReads[index];
			variables.replaceUses(read.placeholder, ownDefinition[index]
				? variables.readAtEntry(read.variable, read.block) : variables.read(read.variable, read.block));
		}
		for (variable in replaced)
			variables.removePhisOf(variable);
		return replaced;
	}

	function rewriteBlock(block:IrBlock, blockStores:Null<Array<IrIteratorStore>>, owner:Map<Int, Int>,
			arrays:Map<Int, Int>, positions:Map<Int, Int>,
			created:Map<Int, {array:IrValue, provenance:SourceProvenance}>):Void {
		var instructions = block.instructions,
			rewritten:Array<Located<IrInstruction>> = [],
			nextStore = 0,
			changed = false;
		inline function storesBefore(index:Int):Void
			while (blockStores != null && nextStore < blockStores.length && blockStores[nextStore].index <= index) {
				var store = blockStores[nextStore++],
					creation = created.get(store.value.id),
					zero = variables.newValue(I32);
				if (creation == null)
					throw new compiler.core.InternalError("A replaced iterator store has no creation");
				variables.write(arrays.get(store.variable), block.id, creation.array);
				rewritten.push(new Located(ConstInt(zero, 0), creation.provenance));
				variables.write(positions.get(store.variable), block.id, zero);
				changed = true;
			}
		for (index in 0...instructions.length) {
			storesBefore(index);
			var located = instructions[index], provenance = located.provenance;
			switch located.value {
				case IteratorNew(output, _) if (owner.exists(output.id) && arrays.exists(owner.get(output.id))):
					changed = true; // the store that follows records the array and a zero position instead
				case IteratorHasNext(output, iterator) if (replacedOwner(iterator, owner, arrays) >= 0):
					var variable = replacedOwner(iterator, owner, arrays),
						array = readHere(arrays.get(variable), block.id),
						position = readHere(positions.get(variable), block.id),
						size = variables.newValue(I32);
					rewritten.push(new Located(ArraySize(size, array), provenance));
					rewritten.push(new Located(Less(output, position, size), provenance));
					changed = true;
				case IteratorNext(output, iterator) if (replacedOwner(iterator, owner, arrays) >= 0):
					var variable = replacedOwner(iterator, owner, arrays),
						array = readHere(arrays.get(variable), block.id),
						position = readHere(positions.get(variable), block.id),
						one = variables.newValue(I32),
						following = variables.newValue(I32);
					rewritten.push(new Located(ArrayGet(output, array, position), provenance));
					rewritten.push(new Located(ConstInt(one, 1), provenance));
					rewritten.push(new Located(Add(following, position, one), provenance));
					variables.write(positions.get(variable), block.id, following);
					changed = true;
				default:
					rewritten.push(located);
			}
		}
		storesBefore(instructions.length);
		if (!changed)
			return;
		instructions.resize(0);
		for (located in rewritten)
			instructions.push(located);
	}

	function replacedOwner(iterator:IrValue, owner:Map<Int, Int>, arrays:Map<Int, Int>):Int {
		var variable = owner.get(variables.find(iterator).id);
		return variable != null && arrays.exists(variable) ? variable : -1;
	}

	/** The variable's value at this point of `block`: its own last definition, or the value at its entry. */
	function readHere(variable:Int, block:Int):IrValue {
		if (variables.definesIn(block, variable))
			return variables.read(variable, block);
		var key = block + ":" + variable, known = entryReadOf.get(key);
		if (known != null)
			return known;
		var placeholder = variables.newValue(variables.variableType(variable));
		entryReadOf.set(key, placeholder);
		entryReads.push({block: block, variable: variable, placeholder: placeholder});
		return placeholder;
	}

	/** Element types for which `array[position]` is exactly what the runtime iterator reads. */
	static function replaceable(element:IrType):Bool
		return switch element {
			case I32, I64, F64, Bool, Bytes, Obj(_): true;
			default: false;
		};
}
