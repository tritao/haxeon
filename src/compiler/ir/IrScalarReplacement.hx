package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Result of a scalar replacement run over one function body. */
typedef ScalarReplacementResult = {
	/** Values whose uses must be rewritten: each removed FieldGet output maps to the field value that reaches it. */
	final substitutions:Map<Int, IrValue>;

	final nextValue:Int;
}

/**
 * Removes allocations of value class instances that are only created, written and read through their fields.
 * Each field of such an object is treated as a variable and put into SSA form: reads become the reaching write,
 * and phis are inserted where writes from different paths meet. A field read before any write takes the zero value
 * HashLink's `New` would have given it.
 *
 * An object is left alone when any use is not a field read or a write to one of its own fields (stored, passed to
 * a call, returned, used in a phi, compared). In a function with exception
 * handling only objects that live in a single block are replaced, because handler edges would need phis of their own.
 */
@:allow(compiler.ir.IrNestedScalarReplacement)
class IrScalarReplacement {
	/** Run independently of inlining, without mutating the source function held by incremental compilation. */
	public static function rewrite(fn:IrFunction, objects:IrObjectTable, forcePhis = false, constructFields = false):IrFunction {
		var blocks:Array<IrBlock> = [], next = 0;
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				copy.instructions.push(located);
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= next) next = output.id + 1;
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		var result = run(blocks, objects, next, forcePhis);
		if (constructFields)
			constructInPlace(blocks, objects, result.nextValue, result.substitutions);
		if (!result.substitutions.keys().hasNext()) {
			// Even a never-read value can have lost its allocation and writes.
			var changed = false;
			for (index in 0...blocks.length)
				if (blocks[index].instructions.length != fn.blocks[index].instructions.length) changed = true;
				else for (position in 0...blocks[index].instructions.length)
					if (blocks[index].instructions[position] != fn.blocks[index].instructions[position]) changed = true;
			if (!changed) return fn;
		}
		var bindings = IrInliner.substitute(blocks, result.substitutions, fn.debugBindings);
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, bindings, fn.inlineHint, fn.retention);
	}

	public static function run(blocks:Array<IrBlock>, objects:IrObjectTable, nextValue:Int, forcePhis = false):ScalarReplacementResult {
		var substitutions:Map<Int, IrValue> = [];
		var candidates = findCandidates(blocks, objects);
		if (candidates.length == 0)
			return {substitutions: substitutions, nextValue: nextValue};
		var hasHandlers = false;
		for (block in blocks)
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _), EndTry(_), Catch(_):
						hasHandlers = true;
					default:
				}
		var graph = new IrGraph(new IrFunction("scalar-replacement", [], Void, blocks));
		var frontier = dominanceFrontiers(graph),
			children = dominatorChildren(graph);
		for (found in candidates) {
			// Earlier replacements rewrote blocks, so the allocation's position is looked up again.
			var position = allocationPosition(found.block, found.object);
			if (position < 0)
				continue;
			var candidate = {
				object: found.object,
				typeName: found.typeName,
				block: found.block,
				position: position
			};
			var descriptor = objects.get(candidate.typeName);
			if (descriptor != null && hasValueField(descriptor, objects)) {
				nextValue = IrNestedScalarReplacement.tryReplace(blocks, objects, candidate.object, candidate.typeName, candidate.block,
					candidate.position, hasHandlers, substitutions, nextValue, forcePhis);
				continue;
			}
			if (descriptor == null || !knownFields(blocks, candidate.object, descriptor)) continue;
			if (!usesAreFieldAccesses(blocks, candidate.object, candidate.block, candidate.position, hasHandlers, graph))
				continue;
			nextValue = replace(blocks, graph, frontier, children, candidate, descriptor, substitutions, nextValue, forcePhis);
		}
		return {substitutions: substitutions, nextValue: nextValue};
	}

	static function knownFields(blocks:Array<IrBlock>, object:IrValue, descriptor:IrObject):Bool {
		var names:Map<String, Bool> = [for (field in descriptor.fields) field.name => true];
		for (block in blocks) for (located in block.instructions) switch located.value {
			case FieldGet(_, target, name), FieldSet(target, name, _) if (target.id == object.id && !names.exists(name)): return false;
			default:
		}
		return true;
	}

	/**
	 * For targets where a value class field is stored inline in its parent and reading it yields a pointer into the
	 * parent (HashLink), `dest.field = new V(...)` allocates a struct only to copy it into place. When the new
	 * instance is only written and then stored, write its fields straight into the parent's slot instead: take the
	 * slot with FieldGet, then FieldSet each field (unwritten fields get the zero `New` would have given them).
	 */
	public static function constructInPlace(blocks:Array<IrBlock>, objects:IrObjectTable, nextValue:Int, substitutions:Map<Int, IrValue>):Int {
		for (block in blocks) {
			var position = 0;
			while (position < block.instructions.length) {
				var located = block.instructions[position];
				switch located.value {
					case NewObject(object, typeName):
						var descriptor = objects.get(typeName);
						if (descriptor != null && descriptor.isValue && hasValueField(descriptor, objects)) {
							nextValue = IrNestedScalarReplacement.constructInPlace(blocks, objects, object, typeName, block, position, substitutions, nextValue);
							if (allocationPosition(block, object) < 0) continue;
						} else if (descriptor != null && descriptor.isValue) {
							var store = storeOnly(blocks, block, position, object);
							if (store != null && parentSlotIsInline(store.destination, store.field, typeName, objects)) {
								nextValue = placeInSlot(block, position, object, descriptor, store, nextValue);
								continue;
							}
						}
					default:
				}
				position++;
			}
		}
		return nextValue;
	}

	/** The single store of `object` into another object's field, when every other use is a write to one of its own fields. */
	static function storeOnly(blocks:Array<IrBlock>, home:IrBlock, allocation:Int, object:IrValue):Null<{position:Int, destination:IrValue, field:String}> {
		var found:Null<{position:Int, destination:IrValue, field:String}> = null;
		for (block in blocks) {
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				switch instruction {
					case Phi(_, inputs):
						for (input in inputs)
							if (input.value.id == object.id)
								return null;
					default:
				}
				var uses = 0;
				for (input in IrOperands.inputs(instruction))
					if (input.id == object.id)
						uses++;
				if (uses == 0)
					continue;
				if (block != home || position <= allocation)
					return null;
				switch instruction {
					case FieldSet(target, _, value) if (target.id == object.id && value.id != object.id):
					case FieldSet(target, name, value) if (value.id == object.id && target.id != object.id && uses == 1 && found == null):
						found = {position: position, destination: target, field: name};
					default:
						return null;
				}
			}
			var terminator = block.terminator;
			if (terminator == null)
				continue;
			switch terminator.value {
				case Return(value), Throw(value), Rethrow(value):
					if (value.id == object.id)
						return null;
				case Branch(condition, _, _):
					if (condition.id == object.id)
						return null;
				case Jump(_):
			}
		}
		if (found == null)
			return null;
		// Every write to the new instance must come before the store, or the copy would have missed it.
		for (position in found.position + 1...home.instructions.length)
			switch home.instructions[position].value {
				case FieldSet(target, _, _) if (target.id == object.id):
					return null;
				default:
			}
		return found;
	}

	static function parentSlotIsInline(destination:IrValue, field:String, typeName:String, objects:IrObjectTable):Bool {
		var parentName = switch destination.type {
			case Obj(name): name;
			default: return false;
		};
		var parent = objects.get(parentName);
		if (parent == null)
			return false;
		for (candidate in parent.fields)
			if (candidate.name == field)
				return switch candidate.type {
					case Obj(name): name == typeName;
					default: false;
				};
		return false;
	}

	static function placeInSlot(block:IrBlock, allocation:Int, object:IrValue, descriptor:IrObject, store:{position:Int, destination:IrValue, field:String},
			nextValue:Int):Int {
		// The latest write to each field before the store is the value the copy would have carried.
		var written:Map<String, IrValue> = [];
		for (position in allocation + 1...store.position)
			switch block.instructions[position].value {
				case FieldSet(target, name, value) if (target.id == object.id):
					written.set(name, value);
				default:
			}
		var provenance = block.instructions[store.position].provenance;
		var slot = new IrValue(nextValue++, store.field, Obj(descriptor.name));
		var emitted:Array<Located<IrInstruction>> = [new Located(FieldGet(slot, store.destination, store.field), provenance)];
		for (field in descriptor.fields) {
			var value = written.get(field.name);
			if (value == null) {
				value = new IrValue(nextValue++, object.name + "." + field.name, field.type);
				emitted.push(new Located(zeroValue(value, field.type), provenance));
			}
			emitted.push(new Located(FieldSet(slot, field.name, value), provenance));
		}
		var rewritten:Array<Located<IrInstruction>> = [];
		for (position in 0...block.instructions.length) {
			if (position == allocation)
				continue;
			var instruction = block.instructions[position];
			if (position == store.position) {
				for (added in emitted)
					rewritten.push(added);
				continue;
			}
			if (position > allocation && position < store.position)
				switch instruction.value {
					case FieldSet(target, _, _) if (target.id == object.id):
						continue;
					default:
				}
			rewritten.push(instruction);
		}
		block.instructions.resize(0);
		for (kept in rewritten)
			block.instructions.push(kept);
		return nextValue;
	}

	static function allocationPosition(block:IrBlock, object:IrValue):Int {
		for (position in 0...block.instructions.length)
			switch block.instructions[position].value {
				case NewObject(out, _) if (out.id == object.id):
					return position;
				default:
			}
		return -1;
	}

	static function findCandidates(blocks:Array<IrBlock>, objects:IrObjectTable):Array<{
		object:IrValue,
		typeName:String,
		block:IrBlock,
		position:Int
	}> {
		var found:Array<{
			object:IrValue,
			typeName:String,
			block:IrBlock,
			position:Int
		}> = [];
		for (block in blocks)
			for (position in 0...block.instructions.length)
				switch block.instructions[position].value {
					case NewObject(object, typeName):
						var descriptor = objects.get(typeName);
						if (descriptor != null && descriptor.isValue)
							found.push({
								object: object,
								typeName: typeName,
								block: block,
								position: position
							});
					default:
				}
		return found;
	}

	/** A nested value class field defaults to a zeroed struct, not null, so its default read is not a constant. */
	static function hasValueField(descriptor:IrObject, objects:IrObjectTable):Bool {
		for (field in descriptor.fields)
			switch field.type {
				case Obj(name):
					var nested = objects.get(name);
					if (nested == null || nested.isValue)
						return true;
				default:
			}
		return false;
	}

	/**
	 * Every use of `object` is a field read or a write to one of its fields, after the allocation, and in the same
	 * block as the allocation when the function has exception handling.
	 */
	static function usesAreFieldAccesses(blocks:Array<IrBlock>, object:IrValue, home:IrBlock, allocation:Int, singleBlock:Bool, graph:IrGraph):Bool {
		for (block in blocks) {
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				switch instruction {
					case Phi(_, inputs):
						for (input in inputs)
							if (input.value.id == object.id)
								return false;
					default:
				}
				var uses = 0;
				for (input in IrOperands.inputs(instruction))
					if (input.id == object.id)
						uses++;
				if (uses == 0)
					continue;
				if (block == home) {
					if (position <= allocation)
						return false;
				} else if (singleBlock || !graph.blocks.exists(block.id))
					return false;
				switch instruction {
					case FieldGet(_, target, _) if (target.id == object.id):
					case FieldSet(target, _, value) if (target.id == object.id && value.id != object.id):
					default:
						return false;
				}
			}
			var terminator = block.terminator;
			if (terminator == null)
				continue;
			switch terminator.value {
				case Return(value), Throw(value), Rethrow(value):
					if (value.id == object.id)
						return false;
				case Branch(condition, _, _):
					if (condition.id == object.id)
						return false;
				case Jump(_):
			}
		}
		return true;
	}

	static function dominanceFrontiers(graph:IrGraph):Map<Int, Array<Int>> {
		var frontier:Map<Int, Array<Int>> = [];
		for (id in graph.order)
			frontier.set(id, []);
		for (id in graph.order) {
			var preds = graph.predecessors.get(id);
			if (preds == null || preds.length < 2)
				continue;
			for (pred in preds) {
				var runner = pred, guard = 0;
				while (graph.immediate.exists(runner) && runner != graph.immediate.get(id) && guard <= graph.order.length) {
					var entries = frontier.get(runner);
					if (entries.indexOf(id) < 0)
						entries.push(id);
					var parent = graph.immediate.get(runner);
					if (parent == null || parent == runner)
						break;
					runner = parent;
					guard++;
				}
			}
		}
		return frontier;
	}

	static function dominatorChildren(graph:IrGraph):Map<Int, Array<Int>> {
		var children:Map<Int, Array<Int>> = [];
		for (id in graph.order)
			children.set(id, []);
		for (id in graph.order) {
			var parent = graph.immediate.get(id);
			if (parent != null && parent != id)
				children.get(parent).push(id);
		}
		return children;
	}

	static function replace(blocks:Array<IrBlock>, graph:IrGraph, frontier:Map<Int, Array<Int>>, children:Map<Int, Array<Int>>, candidate:{
		object:IrValue,
		typeName:String,
		block:IrBlock,
		position:Int
	}, descriptor:IrObject, substitutions:Map<Int, IrValue>, nextValue:Int, forcePhis = false):Int {
		var object = candidate.object, home = candidate.block;
		var fieldTypes:Map<String, IrType> = [], fields:Map<String, IrObjectField> = [];
		for (field in descriptor.fields) {
			fieldTypes.set(field.name, field.type);
			fields.set(field.name, field);
		}
		// Which fields are written where, and which are read at all.
		var writers:Map<String, Array<Int>> = [], reads:Map<String, Bool> = [];
		for (block in blocks)
			for (located in block.instructions)
				switch located.value {
					case FieldSet(target, name, _) if (target.id == object.id):
						if (!writers.exists(name))
							writers.set(name, []);
						if (writers.get(name).indexOf(block.id) < 0)
							writers.get(name).push(block.id);
					case FieldGet(_, target, name) if (target.id == object.id):
						reads.set(name, true);
					default:
				}
		// Phis for a field go at the iterated dominance frontier of its writes and of the allocation (the zero default),
		// but only where the object exists, that is, in blocks the allocation's block dominates.
		var phis:Map<Int, Map<String, IrValue>> = [],
			phiInputs:Map<Int, Map<String, Array<IrPhiInput>>> = [];
		for (name in reads.keys()) {
			var work = [home.id], defined:Map<Int, Bool> = [home.id => true];
			var writerBlocks = writers.exists(name) ? writers.get(name) : [];
			for (writer in writerBlocks)
				if (!defined.exists(writer)) {
					defined.set(writer, true);
					work.push(writer);
				}
			var placed:Map<Int, Bool> = [];
			while (work.length > 0) {
				var current = work.pop();
				if (!frontier.exists(current))
					continue;
				for (target in frontier.get(current)) {
					if (placed.exists(target) || !dominates(graph, home.id, target))
						continue;
					placed.set(target, true);
					var output = new IrValue(nextValue++, object.name + "." + name, fieldTypes.get(name));
					if (!phis.exists(target)) {
						phis.set(target, []);
						phiInputs.set(target, []);
					}
					phis.get(target).set(name, output);
					phiInputs.get(target).set(name, []);
					if (!defined.exists(target)) {
						defined.set(target, true);
						work.push(target);
					}
				}
			}
		}
		// Phis cost register moves on every edge, which HashLink's JIT does badly at block boundaries; they only pay off
		// when the allocation they remove runs repeatedly.
		if (!forcePhis && !StringTools.startsWith(candidate.typeName, IrOptionalScalarFlow.WRAPPER)
			&& phis.keys().hasNext() && !inLoop(graph, home.id))
			return nextValue;
		var zeros:Map<String, IrValue> = [],
			zeroInstructions:Array<Located<IrInstruction>> = [];
		var allocation = home.instructions[candidate.position];
		var zeroFor = function(name:String):IrValue {
			var known = zeros.get(name);
			if (known != null)
				return known;
			var type = fieldTypes.get(name);
			var value = new IrValue(nextValue++, object.name + "." + name, type);
			zeros.set(name, value);
			zeroInstructions.push(new Located(zeroValue(value, type), allocation.provenance));
			return value;
		};
		var removed:Map<Int, Map<Int, Bool>> = [], inserted:Map<Int, Map<Int, Array<Located<IrInstruction>>>> = [];
		var markRemoved = function(blockId:Int, position:Int):Void {
			if (!removed.exists(blockId))
				removed.set(blockId, []);
			removed.get(blockId).set(position, true);
		};
		// Rename along the dominator tree from the allocation's block.
		var walk:Int->Map<String, IrValue>->Void = null;
		walk = function(blockId:Int, incoming:Map<String, IrValue>):Void {
			var block = graph.blocks.get(blockId);
			if (block == null)
				throw "Scalar replacement walked to an unknown block";
			var current:Map<String, IrValue> = [for (name => value in incoming) name => value];
			if (phis.exists(blockId))
				for (name => output in phis.get(blockId))
					current.set(name, output);
			var start = blockId == home.id ? candidate.position : -1;
			if (blockId == home.id)
				markRemoved(blockId, candidate.position);
			for (position in start + 1...block.instructions.length) {
				var located = block.instructions[position];
				switch located.value {
					case FieldSet(target, name, value) if (target.id == object.id):
						var stored = resolve(value, substitutions), field = fields.get(name);
						if (field != null && reads.exists(name)) {
							var scratch = new IrBlock(block.id), normalized = normalizeStore(scratch, stored, field, located, nextValue);
							nextValue = normalized.next;
							stored = normalized.value;
							if (scratch.instructions.length > 0) {
								if (!inserted.exists(blockId)) inserted.set(blockId, []);
								inserted.get(blockId).set(position, scratch.instructions);
							}
						}
						current.set(name, stored);
						markRemoved(blockId, position);
					case FieldGet(out, target, name) if (target.id == object.id):
						var known = current.get(name);
						if (known == null)
							known = zeroFor(name);
						substitutions.set(out.id, known);
						markRemoved(blockId, position);
					default:
				}
			}
			for (successor in graph.successors.get(blockId))
				if (phis.exists(successor))
					for (name => output in phis.get(successor)) {
						var known = current.get(name);
						phiInputs.get(successor).get(name).push({block: blockId, value: known == null ? zeroFor(name) : known});
					}
			for (child in children.get(blockId))
				if (dominates(graph, home.id, child))
					walk(child, current);
		};
		walk(home.id, []);
		// Apply: drop the replaced instructions, add the zero defaults after the allocation, and add the phis.
		for (block in blocks) {
			var drop = removed.get(block.id),
				rewritten:Array<Located<IrInstruction>> = [];
			var phiBlock = phis.exists(block.id);
			if (drop == null && !phiBlock)
				continue;
			if (phiBlock)
				for (name => output in phis.get(block.id))
					rewritten.push(new Located(Phi(output, phiInputs.get(block.id).get(name)), allocation.provenance));
			for (position in 0...block.instructions.length) {
				if (inserted.exists(block.id) && inserted.get(block.id).exists(position))
					for (instruction in inserted.get(block.id).get(position)) rewritten.push(instruction);
				if (drop != null && drop.exists(position)) {
					if (block == home && position == candidate.position)
						for (zero in zeroInstructions)
							rewritten.push(zero);
					continue;
				}
				rewritten.push(block.instructions[position]);
			}
			block.instructions.resize(0);
			for (kept in rewritten)
				block.instructions.push(kept);
		}
		return nextValue;
	}

	/** A scalar replacement must preserve the narrowing of a stored native-width field. */
	static function normalizeStore(block:IrBlock, value:IrValue, field:IrObjectField, origin:Located<IrInstruction>,
			next:Int):{value:IrValue, next:Int} {
		var native = field.nativeLayout, width = native == null ? 0 : native.size,
			bits = switch value.type { case I32: 32; case I64: 64; default: 0; };
		if (native != null && bits > 0 && width > 0 && width * 8 < bits) {
			var shift = new IrValue(next++, "$scalar-shift", I32), shifted = new IrValue(next++, "$scalar-truncate", value.type),
				result = new IrValue(next++, "$scalar-extend", value.type);
			block.instructions.push(new Located(ConstInt(shift, bits - width * 8), origin.provenance));
			block.instructions.push(new Located(ShiftLeft(shifted, value, shift), origin.provenance));
			block.instructions.push(new Located(native.signed ? ShiftRight(result, shifted, shift) : UnsignedShiftRight(result, shifted, shift),
				origin.provenance));
			return {value: result, next: next};
		}
		if (value.type == F32) {
			var wide = new IrValue(next++, "$scalar-f64", F64), result = new IrValue(next++, "$scalar-f32", F32);
			block.instructions.push(new Located(FloatToFloat(wide, value), origin.provenance));
			block.instructions.push(new Located(FloatToFloat(result, wide), origin.provenance));
			return {value: result, next: next};
		}
		return {value: value, next: next};
	}

	/** Whether `id` can reach itself again, that is, whether it runs more than once per call. */
	static function inLoop(graph:IrGraph, id:Int):Bool {
		var seen:Map<Int, Bool> = [], work:Array<Int> = [];
		for (successor in graph.successors.get(id))
			work.push(successor);
		while (work.length > 0) {
			var current = work.pop();
			if (current == id)
				return true;
			if (seen.exists(current))
				continue;
			seen.set(current, true);
			for (successor in graph.successors.get(current))
				work.push(successor);
		}
		return false;
	}

	static function dominates(graph:IrGraph, ancestor:Int, block:Int):Bool {
		var current = block, guard = 0;
		while (guard <= graph.order.length) {
			if (current == ancestor)
				return true;
			var parent = graph.immediate.get(current);
			if (parent == null || parent == current)
				return false;
			current = parent;
			guard++;
		}
		return false;
	}

	public static function resolve(value:IrValue, substitutions:Map<Int, IrValue>):IrValue {
		var current = value, steps = 0;
		while (substitutions.exists(current.id) && steps < 4096) {
			current = substitutions.get(current.id);
			steps++;
		}
		return current;
	}

	static function zeroValue(output:IrValue, type:IrType):IrInstruction {
		return switch type {
			case F32, F64: ConstFloat(output, 0.0);
			case Bool: ConstBool(output, false);
			case I32, I64: ConstInt(output, 0);
			default: ConstNull(output);
		};
	}
}
