package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrNestedScalarReplacement.IrBodyNestedScalarReplacement;
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
@:allow(compiler.ir.IrBodyScalarReplacement)
@:allow(compiler.ir.IrBodyNestedScalarReplacement)
class IrScalarReplacement {
	/** Run independently of inlining, without mutating the source function held by incremental compilation. */
	public static function rewrite(fn:IrFunction, objects:IrObjectTable, forcePhis = false,
			constructFields = false):IrFunction {
		// Both replacement and in-place construction require a value allocation. Avoid
		// copying blocks and collecting operands for the other functions in the program.
		var candidate = false;
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case ValueInit(out):
						var object = objects.get(compiler.ir.IrTypeTools.valueObjectName(out.type));
						if (object != null && object.isValue)
							candidate = true;
					default:
				}
			if (candidate)
				break;
		}
		if (!candidate)
			return fn;
		var blocks:Array<IrBlock> = [], next = fn.nextValueId();
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions)
				copy.instructions.push(located);
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
				if (blocks[index].instructions.length != fn.blocks[index].instructions.length)
					changed = true;
				else
					for (position in 0...blocks[index].instructions.length)
						if (blocks[index].instructions[position] != fn.blocks[index].instructions[position])
							changed = true;
			if (!changed)
				return fn;
		}
		var bindings = IrInliner.substitute(blocks, result.substitutions, fn.debugBindings);
		return fn.withBlocks(blocks, bindings);
	}

	/**
	 * `run`, then `constructInPlace` when `constructFields`, then the substitutions, on a body in place: what `rewrite` does,
	 * and what the inliner does after inlining. Removed reads become aliases of the values that reach them, swept before this
	 * returns; whether the body changed.
	 */
	public static function runBody(body:IrBody, objects:IrObjectTable, scratch:IrPassScratch, forcePhis = false,
			constructFields = false):Bool
		return scratch.scalarReplacement.runOn(body, objects, forcePhis, constructFields);

	/**
	 * `rewrite` on `fn`'s body (`bodyIn` with `types`), for the pipeline's stage: `fn` itself when nothing changes, else its
	 * edited body, with the values its decoding would have. The body is edited in
	 * place when the stage owns it, else a copy (one a cache holds is frozen), and the result is owned by the next stage.
	 */
	public static function rewriteBody(fn:IrFunction, objects:IrObjectTable, types:IrTypeIds, scratch:IrPassScratch,
			constructFields:Bool):IrFunction {
		var builder = scratch.bodyBuilder, body = fn.bodyIn(types, builder);
		if (!hasCandidates(body, objects))
			return fn;
		var edited = body.forEditing(builder), before = edited.edits;
		if (!runBody(edited, objects, scratch, false, constructFields) || edited.edits == before)
			return fn;
		edited.keepNamedValues(scratch.namedValues);
		return IrFunction.ofOwnedBody(edited);
	}

	/** Whether `body` allocates a value object, which both replacement and in-place construction need. */
	static function hasCandidates(body:IrBody, objects:IrObjectTable):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ValueInit) {
					var descriptor = objects.get(IrTypeTools.valueObjectName(body.valueType(body.output(row))));
					if (descriptor != null && descriptor.isValue)
						return true;
				}
				row = body.nextRow(row);
			}
		}
		return false;
	}

	public static function run(blocks:Array<IrBlock>, objects:IrObjectTable, nextValue:Int,
			forcePhis = false):ScalarReplacementResult {
		var substitutions:Map<Int, IrValue> = [];
		var candidates = findCandidates(blocks, objects);
		if (candidates.length == 0)
			return {substitutions: substitutions, nextValue: nextValue};
		var hasHandlers = false;
		for (block in blocks)
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _, _), EndTry(_, _), Catch(_):
						hasHandlers = true;
					default:
				}
		var graph = new IrGraph(new IrFunction("scalar-replacement", [], Void, blocks, Ordinary));
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
				nextValue = IrNestedScalarReplacement.tryReplace(blocks, objects, candidate.object, candidate.typeName,
					candidate.block, candidate.position,
					hasHandlers, substitutions, nextValue, forcePhis);
				continue;
			}
			if (descriptor == null || !knownFields(blocks, candidate.object, descriptor))
				continue;
			if (!usesAreFieldAccesses(blocks, candidate.object, candidate.block, candidate.position, hasHandlers,
				graph))
				continue;
			nextValue = replace(blocks, graph, frontier, children, candidate, descriptor, substitutions, nextValue,
				forcePhis);
		}
		return {substitutions: substitutions, nextValue: nextValue};
	}

	static function knownFields(blocks:Array<IrBlock>, object:IrValue, descriptor:IrObject):Bool {
		var names:Map<String, Bool> = [for (field in descriptor.fields) field.name => true];
		for (block in blocks)
			for (located in block.instructions)
				switch located.value {
					case FieldGet(_, target, name),
						FieldSet(target, name, _) if (target.id == object.id && !names.exists(name)):
						return false;
					default:
				}
		return true;
	}

	/**
	 * For targets where value fields are inline (HashLink), expand copies of a fresh value into field places and
	 * scalar-replace the source when all of its uses permit it. Reads, multiple stores and branches may use the
	 * same snapshot. Unsupported escapes retain the original allocation. A simple store-only construction also
	 * has a direct path that writes its fields into the parent's slot.
	 */
	public static function constructInPlace(blocks:Array<IrBlock>, objects:IrObjectTable, nextValue:Int,
			substitutions:Map<Int, IrValue>):Int {
		var stored:Map<Int, Bool> = [];
		for (block in blocks)
			for (located in block.instructions)
				switch located.value {
					case FieldSet(_, _, value):
						stored.set(value.id, true);
					default:
				}
		for (block in blocks) {
			var position = 0;
			while (position < block.instructions.length) {
				var located = block.instructions[position];
				switch located.value {
					case ValueInit(object):
						var typeName = compiler.ir.IrTypeTools.valueObjectName(object.type);
						var descriptor = objects.get(typeName);
						if (descriptor != null && descriptor.isValue && stored.exists(object.id)) {
							nextValue = IrNestedScalarReplacement.constructInPlace(blocks, objects, object, typeName,
								block, position, substitutions,
								nextValue);
							if (allocationPosition(block, object) < 0)
								continue;
							if (!hasValueField(descriptor, objects)) {
								var store = storeOnly(blocks, block, position, object);
								if (store != null
									&& parentSlotIsInline(store.destination, store.field, typeName, objects)) {
									nextValue = placeInSlot(block, position, object, descriptor, store, nextValue);
									continue;
								}
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
	static function storeOnly(blocks:Array<IrBlock>, home:IrBlock, allocation:Int, object:IrValue):Null<{
		position:Int,
		destination:IrValue,
		field:String
	}> {
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
				for (inputIndex in 0...IrOperands.count(instruction)) {
					var input = IrOperands.at(instruction, inputIndex);
					if (input.id == object.id)
						uses++;
				}
				if (uses == 0)
					continue;
				if (block != home || position <= allocation)
					return null;
				switch instruction {
					case FieldSet(target, _, value) if (target.id == object.id && value.id != object.id):
					case FieldSet(target, name,
						value) if (value.id == object.id && target.id != object.id && uses == 1 && found == null):
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
				case Branch(condition, _, _), Switch(condition, _, _):
					if (condition.id == object.id)
						return null;
				case Jump(_), Unreachable:
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

	static function parentSlotIsInline(destination:IrValue, field:String, typeName:String, objects:IrObjectTable):Bool
		return parentSlotTypeIsInline(destination.type, field, typeName, objects);

	static function parentSlotTypeIsInline(destination:IrType, field:String, typeName:String,
			objects:IrObjectTable):Bool {
		var parentName = switch destination {
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

	static function placeInSlot(block:IrBlock, allocation:Int, object:IrValue, descriptor:IrObject, store:{
		position:Int,
		destination:IrValue,
		field:String
	},
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
		var emitted:Array<Located<IrInstruction>> = [new Located(FieldGet(slot, store.destination, store.field),
			provenance)];
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
				case ValueInit(out) if (out.id == object.id):
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
					case ValueInit(object):
						var typeName = compiler.ir.IrTypeTools.valueObjectName(object.type);
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
	static function usesAreFieldAccesses(blocks:Array<IrBlock>, object:IrValue, home:IrBlock, allocation:Int,
			singleBlock:Bool, graph:IrGraph):Bool {
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
				for (inputIndex in 0...IrOperands.count(instruction)) {
					var input = IrOperands.at(instruction, inputIndex);
					if (input.id == object.id)
						uses++;
				}
				if (uses == 0)
					continue;
				if (block == home) {
					if (position <= allocation)
						return false;
				} else if (singleBlock || !graph.contains(block.id))
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
				case Branch(condition, _, _), Switch(condition, _, _):
					if (condition.id == object.id)
						return false;
				case Jump(_), Unreachable:
			}
		}
		return true;
	}

	static function dominanceFrontiers(graph:IrGraph):Map<Int, Array<Int>> {
		var frontier:Map<Int, Array<Int>> = [];
		for (id in graph.order)
			frontier.set(id, []);
		for (id in graph.order) {
			if (graph.predecessorCount(id) < 2)
				continue;
			for (index in 0...graph.predecessorCount(id)) {
				var runner = graph.predecessor(id, index), guard = 0;
				while (graph.isReachable(runner) && runner != graph.immediateDominator(id)
					&& guard <= graph.order.length) {
					var entries = frontier.get(runner);
					if (entries.indexOf(id) < 0)
						entries.push(id);
					var parent = graph.immediateDominator(runner);
					if (parent < 0 || parent == runner)
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
			var parent = graph.immediateDominator(id);
			if (parent >= 0 && parent != id)
				children.get(parent).push(id);
		}
		return children;
	}

	static function replace(blocks:Array<IrBlock>, graph:IrGraph, frontier:Map<Int, Array<Int>>,
			children:Map<Int, Array<Int>>, candidate:{
				object:IrValue,
				typeName:String,
				block:IrBlock,
				position:Int
			}, descriptor:IrObject, substitutions:Map<Int, IrValue>,
			nextValue:Int, forcePhis = false):Int {
		var object = candidate.object, home = candidate.block;
		var fieldTypes:Map<String, IrType> = [],
			fields:Map<String, IrObjectField> = [];
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
			while (true) {
				var current = work.pop();
				if (current == null)
					break;
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
		if (!forcePhis
			&& !StringTools.startsWith(candidate.typeName, IrOptionalScalarFlow.WRAPPER)
			&& phis.keys().hasNext()
			&& !inLoop(graph, home.id))
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
		var removed:Map<Int, Map<Int, Bool>> = [],
			inserted:Map<Int, Map<Int, Array<Located<IrInstruction>>>> = [];
		var markRemoved = function(blockId:Int, position:Int):Void {
			if (!removed.exists(blockId))
				removed.set(blockId, []);
			removed.get(blockId).set(position, true);
		};
		// Rename along the dominator tree from the allocation's block.
		var work:Array<{blockId:Int, incoming:Map<String, IrValue>}> = [{blockId: home.id, incoming: []}];
		while (work.length > 0) {
			var pending:{blockId:Int, incoming:Map<String, IrValue>} = cast work.pop(),
				blockId = pending.blockId,
				incoming = pending.incoming;
			if (!graph.contains(blockId))
				throw new InternalError("Scalar replacement walked to an unknown block");
			var block = graph.block(blockId);
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
						var stored = resolve(value, substitutions),
							field = fields.get(name);
						if (field != null && reads.exists(name)) {
							var scratch = new IrBlock(block.id),
								normalized = normalizeStore(scratch, stored, field, located, nextValue);
							nextValue = normalized.next;
							stored = normalized.value;
							if (scratch.instructions.length > 0) {
								if (!inserted.exists(blockId))
									inserted.set(blockId, []);
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
			for (edge in 0...graph.successorCount(blockId)) {
				var successor = graph.successor(blockId, edge);
				if (phis.exists(successor))
					for (name => output in phis.get(successor)) {
						var known = current.get(name);
						phiInputs.get(successor).get(name).push({
							block: blockId,
							value: known == null ? zeroFor(name) : known
						});
					}
			}
			var descendants:Array<Int> = cast children.get(blockId);
			var index = descendants.length;
			while (index > 0) {
				var child = descendants[--index];
				// Every child in this traversal is already in the allocation block's dominator subtree.
				work.push({blockId: child, incoming: current});
			}
		}
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
					for (instruction in inserted.get(block.id).get(position))
						rewritten.push(instruction);
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
			next:Int):{
				value:IrValue,
				next:Int
			} {
		var native = IrFieldStorage.scalar(field),
			width = native == null ? 0 : native.size,
			bits = switch value.type {
				case I32: 32;
				case I64: 64;
				default: 0;
			};
		if (native != null && bits > 0 && width > 0 && width * 8 < bits) {
			var shift = new IrValue(next++, "$scalar-shift", I32),
				shifted = new IrValue(next++, "$scalar-truncate", value.type),
				result = new IrValue(next++, "$scalar-extend", value.type);
			block.instructions.push(new Located(ConstInt(shift, bits - width * 8), origin.provenance));
			block.instructions.push(new Located(ShiftLeft(shifted, value, shift), origin.provenance));
			block.instructions.push(new Located(native.signed ? ShiftRight(result, shifted,
				shift) : UnsignedShiftRight(result, shifted, shift),
				origin.provenance));
			return {value: result, next: next};
		}
		if ((switch (value.type) {
			case F32: true;
			default: false;
		})) {
			var wide = new IrValue(next++, "$scalar-f64", F64),
				result = new IrValue(next++, "$scalar-f32", F32);
			block.instructions.push(new Located(FloatToFloat(wide, value), origin.provenance));
			block.instructions.push(new Located(FloatToFloat(result, wide), origin.provenance));
			return {value: result, next: next};
		}
		return {value: value, next: next};
	}

	/** Whether `id` can reach itself again, that is, whether it runs more than once per call. */
	static function inLoop(graph:IrGraph, id:Int):Bool {
		var seen:Map<Int, Bool> = [], work:Array<Int> = [];
		for (index in 0...graph.successorCount(id))
			work.push(graph.successor(id, index));
		while (true) {
			var current = work.pop();
			if (current == null)
				break;
			if (current == id)
				return true;
			if (seen.exists(current))
				continue;
			seen.set(current, true);
			for (index in 0...graph.successorCount(current))
				work.push(graph.successor(current, index));
		}
		return false;
	}

	static function dominates(graph:IrGraph, ancestor:Int, block:Int):Bool {
		var current = block, guard = 0;
		while (guard <= graph.order.length) {
			if (current == ancestor)
				return true;
			var parent = graph.immediateDominator(current);
			if (parent < 0 || parent == current)
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

/**
 * `IrScalarReplacement` on a body, in place, with the same result: replaced reads unlinked and their outputs made aliases of
 * the values that reach them, new values numbered from the body's `valueLimit` in the order the object version numbers them,
 * phis linked at block starts. Its tables are kept from one function to the next (`IrPassScratch.scalarReplacement`); the
 * maps keyed by field name stay maps, because the object version's phis come in their iteration order.
 */
@:allow(compiler.ir.IrScalarReplacement)
@:allow(compiler.ir.IrBodyNestedScalarReplacement)
class IrBodyScalarReplacement {
	var body:Null<IrBody> = null;
	var objects:Null<IrObjectTable> = null;
	final graph = new IrBodyGraph();

	/** Whether `graph` and the tables made from it are the current body's. */
	var graphReady = false;

	/** The candidates: allocation output, the index of its block, its type's name. */
	final candidateValues:Array<Int> = [];

	final candidateBlocks:Array<Int> = [];
	final candidateTypes:Array<String> = [];

	/**
	 * Per block id, its dominance frontier in the order found, as a list of entries of `frontierTargets` from `frontierHead`
	 * through `frontierNext`.
	 */
	final frontierHead:Array<Int> = [];

	final frontierTail:Array<Int> = [];
	final frontierNext:Array<Int> = [];
	final frontierTargets:Array<Int> = [];

	/** Per block id, its children in the dominator tree as a run of `childList`. */
	final childStart:Array<Int> = [];

	final childCount:Array<Int> = [];
	final childList:Array<Int> = [];

	/** The replaced object's fields: symbol ids, and whether each is read. */
	final fieldSymbols:Array<Int> = [];

	final fieldRead:Array<Bool> = [];

	/** Writes as (field, block id) pairs, each once, in the order met. */
	final writerFields:Array<Int> = [];

	final writerBlocks:Array<Int> = [];

	/** Phis as placed: block id, field, value; their inputs as (phi, block id, value) triples in the order met. */
	final phiBlocks:Array<Int> = [];

	final phiFields:Array<Int> = [];
	final phiValues:Array<Int> = [];
	final phiInputs:Array<Int> = [];

	/** Per block id, its phis by field name (the index of each in `phiBlocks`), or null. */
	final phisAt:Array<Null<Map<String, Int>>> = [];

	/** Per field, the value of its zero default, or -1. */
	final zeros:Array<Int> = [];

	/** Per block index and field, the value reaching the block's end, or -1. */
	final state:Array<Int> = [];

	/** Stamps by block id for the walks that mark blocks. */
	final defined:Array<Int> = [];

	final placed:Array<Int> = [];
	var stamp = 0;
	final work:Array<Int> = [];
	final workParents:Array<Int> = [];

	/** Values a `FieldSet` stores, for `constructInPlace`. */
	final stored = new IrPassScratch.IrValueMarks();

	/** Per field, the latest value written before a store-only copy (`placeInSlot`). */
	final written:Array<Int> = [];

	/** `storeOnly`'s answer. */
	var storeRow = -1;

	var storeDestination = IrValueId.of(-1);
	var storeField = -1;

	/** Where the zero defaults go: after this row of the allocation's block, -1 for its start. */
	var zeroAnchor = -1;

	var zeroBlock = -1;
	var zeroProvenance:Null<SourceProvenance> = null;

	/** What a nested replacement may have to undo (`IrBody.beginTrial`). */
	final trial = new IrBody.IrBodyTrial();

	/** The tables of the nested replacement. */
	final nested = new IrBodyNestedScalarReplacement();

	public function new() {}

	/** `run`, then `constructInPlace` when `constructFields`, then the aliases swept; whether the body changed. */
	function runOn(body:IrBody, objects:IrObjectTable, forcePhis:Bool, constructFields:Bool):Bool {
		this.body = body;
		this.objects = objects;
		graphReady = false;
		var changed = false;
		if (findCandidates() > 0) {
			changed = replaceCandidates(forcePhis);
			if (constructFields && constructInPlace())
				changed = true;
			body.sweepAliases();
		}
		for (index in 0...phisAt.length)
			phisAt[index] = null;
		this.body = null;
		this.objects = null;
		graphReady = false;
		zeroProvenance = null;
		candidateTypes.resize(0);
		nested.release();
		return changed;
	}

	/** The graph, its dominance frontiers and dominator children, made once per function: this pass never changes edges. */
	function prepareGraph():IrBodyGraph {
		var graph = this.graph;
		if (graphReady)
			return graph;
		graphReady = true;
		graph.reset(body);
		var size = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		IrPassScratch.filledInts(frontierHead, size, -1);
		IrPassScratch.filledInts(frontierTail, size, -1);
		frontierNext.resize(0);
		frontierTargets.resize(0);
		var order = graph.order;
		for (id in order) {
			if (graph.predecessorCount(id) < 2)
				continue;
			for (index in 0...graph.predecessorCount(id)) {
				var runner = graph.predecessor(id, index), guard = 0;
				while (graph.isReachable(runner) && runner != graph.immediateDominator(id) && guard <= order.length) {
					addFrontier(runner, id);
					var parent = graph.immediateDominator(runner);
					if (parent < 0 || parent == runner)
						break;
					runner = parent;
					guard++;
				}
			}
		}
		IrPassScratch.filledInts(childStart, size, 0);
		IrPassScratch.filledInts(childCount, size, 0);
		for (id in order) {
			var parent = graph.immediateDominator(id);
			if (parent >= 0 && parent != id)
				childCount[parent]++;
		}
		var offset = 0;
		for (id in 0...size) {
			childStart[id] = offset;
			offset += childCount[id];
			childCount[id] = 0;
		}
		childList.resize(offset);
		for (id in order) {
			var parent = graph.immediateDominator(id);
			if (parent >= 0 && parent != id)
				childList[childStart[parent] + childCount[parent]++] = id;
		}
		while (phisAt.length < size)
			phisAt.push(null);
		while (defined.length < size) {
			defined.push(0);
			placed.push(0);
		}
		return graph;
	}

	function addFrontier(block:Int, target:Int):Void {
		var entry = frontierHead[block];
		while (entry >= 0) {
			if (frontierTargets[entry] == target)
				return;
			entry = frontierNext[entry];
		}
		var added = frontierTargets.length;
		frontierTargets.push(target);
		frontierNext.push(-1);
		if (frontierTail[block] >= 0)
			frontierNext[frontierTail[block]] = added;
		else
			frontierHead[block] = added;
		frontierTail[block] = added;
	}

	function findCandidates():Int {
		candidateValues.resize(0);
		candidateBlocks.resize(0);
		candidateTypes.resize(0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ValueInit) {
					var object = body.output(row),
						typeName = IrTypeTools.valueObjectName(body.valueType(object)),
						descriptor = objects.get(typeName);
					if (descriptor != null && descriptor.isValue) {
						candidateValues.push(object);
						candidateBlocks.push(block);
						candidateTypes.push(typeName);
					}
				}
				row = body.nextRow(row);
			}
		}
		return candidateValues.length;
	}

	/** `IrScalarReplacement.run`. */
	function replaceCandidates(forcePhis:Bool):Bool {
		var hasHandlers = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.BeginTry, IrOpcode.EndTry, IrOpcode.Catch:
						hasHandlers = true;
					default:
				}
				row = body.nextRow(row);
			}
		}
		prepareGraph();
		var changed = false;
		for (candidate in 0...candidateValues.length) {
			var object = IrValueId.of(candidateValues[candidate]),
				home = candidateBlocks[candidate],
				typeName = candidateTypes[candidate];
			// Earlier replacements rewrote rows, so whether the allocation is still there is looked up again.
			var allocation = body.definingRow(object);
			if (allocation < 0)
				continue;
			var descriptor = objects.get(typeName);
			if (descriptor != null && IrScalarReplacement.hasValueField(descriptor, objects)) {
				if (nested.tryReplace(this, object, typeName, home, allocation, hasHandlers, forcePhis, true))
					changed = true;
				continue;
			}
			if (descriptor == null || !knownFields(object, descriptor))
				continue;
			if (!usesAreFieldAccesses(object, home, allocation, hasHandlers))
				continue;
			if (replace(object, typeName, home, allocation, descriptor, forcePhis))
				changed = true;
		}
		return changed;
	}

	function setFields(descriptor:IrObject):Void {
		fieldSymbols.resize(0);
		for (field in descriptor.fields)
			fieldSymbols.push(IrSymbol.of(field.name).id);
	}

	/** The field with symbol id `symbol`, the last of that name as a map by name would give, or -1. */
	function fieldIndex(symbol:Int):Int {
		var index = fieldSymbols.length;
		while (index > 0)
			if (fieldSymbols[--index] == symbol)
				return index;
		return -1;
	}

	function knownFields(object:IrValueId, descriptor:IrObject):Bool {
		setFields(descriptor);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.FieldGet, IrOpcode.FieldSet:
						if (body.operand(row, 0) == object && fieldIndex(body.aux(row)) < 0)
							return false;
					default:
				}
				row = body.nextRow(row);
			}
		}
		return true;
	}

	/** `IrScalarReplacement.usesAreFieldAccesses`: rows up to the allocation in its block count as before it. */
	function usesAreFieldAccesses(object:IrValueId, home:Int, allocation:Int, singleBlock:Bool):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), after = false;
			while (row >= 0) {
				var opcode = body.opcode(row), count = body.operandCount(row);
				if (opcode.isTerminator()) {
					if (count > 0 && body.operand(row, 0) == object)
						return false;
				} else if (opcode == IrOpcode.Phi) {
					for (index in 0...count)
						if (body.operand(row, index) == object)
							return false;
				} else {
					var uses = 0;
					for (index in 0...count)
						if (body.operand(row, index) == object)
							uses++;
					if (uses > 0) {
						if (block == home) {
							if (!after)
								return false;
						} else if (singleBlock || !graph.contains(body.blockId(block)))
							return false;
						switch opcode {
							case IrOpcode.FieldGet:
							case IrOpcode.FieldSet if (body.operand(row, 1) != object):
							default:
								return false;
						}
					}
				}
				if (row == allocation)
					after = true;
				row = body.nextRow(row);
			}
		}
		return true;
	}

	/** `IrScalarReplacement.replace`; whether it replaced the object, or declined phis that would not pay. */
	function replace(object:IrValueId, typeName:String, home:Int, allocation:Int, descriptor:IrObject,
			forcePhis:Bool):Bool {
		var graph = this.graph, homeId = body.blockId(home), fields = descriptor.fields;
		setFields(descriptor);
		IrPassScratch.filledBools(fieldRead, fields.length, false);
		writerFields.resize(0);
		writerBlocks.resize(0);
		// Which fields are written where, and which are read; the reads by name, as the phis come in that map's order.
		var reads:Map<String, Bool> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), id = body.blockId(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if ((opcode == IrOpcode.FieldSet || opcode == IrOpcode.FieldGet) && body.operand(row, 0) == object) {
					var field = requiredField(body.aux(row));
					if (opcode == IrOpcode.FieldSet) {
						var known = false;
						for (index in 0...writerFields.length)
							if (writerFields[index] == field && writerBlocks[index] == id)
								known = true;
						if (!known) {
							writerFields.push(field);
							writerBlocks.push(id);
						}
					} else {
						reads.set(fields[field].name, true);
						fieldRead[field] = true;
					}
				}
				row = body.nextRow(row);
			}
		}
		// Phis at the iterated dominance frontier of each read field's writes and of the allocation, where the object exists.
		phiBlocks.resize(0);
		phiFields.resize(0);
		phiValues.resize(0);
		phiInputs.resize(0);
		for (name in reads.keys()) {
			var field = fieldByName(fields, name);
			stamp++;
			var definedStamp = stamp;
			stamp++;
			var placedStamp = stamp;
			work.resize(0);
			work.push(homeId);
			defined[homeId] = definedStamp;
			for (index in 0...writerFields.length) {
				var writer = writerBlocks[index];
				if (writerFields[index] == field && defined[writer] != definedStamp) {
					defined[writer] = definedStamp;
					work.push(writer);
				}
			}
			while (work.length > 0) {
				var current = work.pop();
				if (!graph.isReachable(current))
					continue;
				var entry = frontierHead[current];
				while (entry >= 0) {
					var target = frontierTargets[entry];
					entry = frontierNext[entry];
					if (placed[target] == placedStamp || !dominates(homeId, target))
						continue;
					placed[target] = placedStamp;
					var phis = phisAt[target];
					if (phis == null) {
						phis = [];
						phisAt[target] = phis;
					}
					phis.set(name, phiBlocks.length);
					phiBlocks.push(target);
					phiFields.push(field);
					if (defined[target] != definedStamp) {
						defined[target] = definedStamp;
						work.push(target);
					}
				}
			}
		}
		// Phis cost register moves on every edge; they only pay off when the allocation they remove runs repeatedly.
		if (!forcePhis
			&& !StringTools.startsWith(typeName, IrOptionalScalarFlow.WRAPPER)
			&& phiBlocks.length > 0
			&& !inLoop(homeId)) {
			for (target in phiBlocks)
				phisAt[target] = null;
			// The object version numbered the phis before declining them.
			for (_ in 0...phiBlocks.length)
				body.skipValue();
			return false;
		}
		var objectName = body.valueName(object);
		for (index in 0...phiBlocks.length) {
			var field = fields[phiFields[index]];
			phiValues.push(body.newValue(objectName + "." + field.name, body.typeId(field.type)));
		}
		IrPassScratch.filledInts(zeros, fields.length, -1);
		var fieldCount = fields.length;
		IrPassScratch.filledInts(state, body.blockCount() * fieldCount, -1);
		zeroBlock = home;
		zeroAnchor = body.previousRow(allocation);
		zeroProvenance = body.provenance(allocation);
		// Rename along the dominator tree from the allocation's block.
		work.resize(0);
		workParents.resize(0);
		work.push(homeId);
		workParents.push(-1);
		while (work.length > 0) {
			var id = work.pop(), parent = workParents.pop();
			if (!graph.contains(id))
				throw new InternalError("Scalar replacement walked to an unknown block");
			var block = graph.indexOf(id), base = block * fieldCount;
			for (field in 0...fieldCount)
				state[base + field] = parent < 0 ? -1 : state[parent * fieldCount + field];
			var phis = phisAt[id];
			if (phis != null)
				for (_ => phi in phis)
					state[base + phiFields[phi]] = phiValues[phi];
			var row = body.firstRow(block);
			if (id == homeId) {
				row = body.nextRow(allocation);
				body.removeRow(block, allocation);
			}
			while (row >= 0) {
				var next = body.nextRow(row), opcode = body.opcode(row);
				if ((opcode == IrOpcode.FieldSet || opcode == IrOpcode.FieldGet) && body.operand(row, 0) == object) {
					var field = requiredField(body.aux(row));
					if (opcode == IrOpcode.FieldSet) {
						var value = body.resolve(body.operand(row, 1));
						if (fieldRead[field])
							value = normalizeStore(block, row, value, fields[field]);
						state[base + field] = value;
					} else {
						var known = state[base + field];
						body.alias(body.output(row),
							IrValueId.of(known >= 0 ? known : zeroFor(field, fields[field], objectName)));
					}
					body.removeRow(block, row);
				}
				row = next;
			}
			for (edge in 0...graph.successorCount(id)) {
				var successor = graph.successor(id, edge), successorPhis = phisAt[successor];
				if (successorPhis != null)
					for (_ => phi in successorPhis) {
						var field = phiFields[phi], known = state[base + field];
						phiInputs.push(phi);
						phiInputs.push(id);
						phiInputs.push(known >= 0 ? known : zeroFor(field, fields[field], objectName));
					}
			}
			var index = childCount[id];
			while (index > 0) {
				work.push(childList[childStart[id] + --index]);
				workParents.push(block);
			}
		}
		// The phis go first in their blocks, in the order of their block's map.
		for (block in 0...body.blockCount()) {
			var id = body.blockId(block), phis = phisAt[id];
			if (phis == null)
				continue;
			var after = -1;
			for (_ => phi in phis) {
				body.beginRow();
				for (input in 0...Std.int(phiInputs.length / 3))
					if (phiInputs[input * 3] == phi)
						body.pushOperand(IrValueId.of(phiInputs[input * 3 + 2]));
				var start = 0, first = true;
				for (input in 0...Std.int(phiInputs.length / 3))
					if (phiInputs[input * 3] == phi) {
						var at = body.pushInt(phiInputs[input * 3 + 1]);
						if (first)
							start = at;
						first = false;
					}
				var row = body.endRow(IrOpcode.Phi, IrValueId.of(phiValues[phi]), start, zeroProvenance);
				body.linkAfter(block, after, row);
				after = row;
			}
			phisAt[id] = null;
		}
		return true;
	}

	/** `IrScalarReplacement.dominates`. */
	function dominates(ancestor:Int, block:Int):Bool {
		var current = block, guard = 0, limit = graph.order.length;
		while (guard <= limit) {
			if (current == ancestor)
				return true;
			var parent = graph.immediateDominator(current);
			if (parent < 0 || parent == current)
				return false;
			current = parent;
			guard++;
		}
		return false;
	}

	/** Whether block `id` can reach itself again, that is, whether it runs more than once per call. */
	function inLoop(id:Int):Bool {
		var seen = ++stamp;
		work.resize(0);
		for (index in 0...graph.successorCount(id))
			work.push(graph.successor(id, index));
		while (work.length > 0) {
			var current = work.pop();
			if (current == id)
				return true;
			if (defined[current] == seen)
				continue;
			defined[current] = seen;
			for (index in 0...graph.successorCount(current))
				work.push(graph.successor(current, index));
		}
		return false;
	}

	function requiredField(symbol:Int):Int {
		var field = fieldIndex(symbol);
		if (field < 0)
			throw new InternalError('Scalar replacement met field "${IrSymbol.at(symbol).name}", which its object does not have');
		return field;
	}

	static function fieldByName(fields:Array<IrObjectField>, name:String):Int {
		var index = fields.length;
		while (index > 0)
			if (fields[--index].name == name)
				return index;
		throw new InternalError('Scalar replacement read field "$name", which its object does not have');
	}

	/** The zero default of `field`, made the first time it is needed, after the earlier ones where the allocation was. */
	function zeroFor(field:Int, declared:IrObjectField, objectName:String):Int {
		var known = zeros[field];
		if (known >= 0)
			return known;
		var value = body.newValue(objectName + "." + declared.name, body.typeId(declared.type));
		zeros[field] = value;
		var row = zeroRow(body, value, declared.type, zeroProvenance);
		body.linkAfter(zeroBlock, zeroAnchor, row);
		zeroAnchor = row;
		return value;
	}

	/** `IrScalarReplacement.zeroValue` as a row, unlinked. */
	static function zeroRow(body:IrBody, output:IrValueId, type:IrType, provenance:SourceProvenance):Int {
		body.beginRow();
		return switch type {
			case F32, F64: body.endRow(IrOpcode.ConstFloat, output, body.addFloat(0.0), provenance);
			case Bool: body.endRow(IrOpcode.ConstBool, output, 0, provenance);
			case I32, I64: body.endRow(IrOpcode.ConstInt, output, 0, provenance);
			default: body.endRow(IrOpcode.ConstNull, output, 0, provenance);
		};
	}

	/** `IrScalarReplacement.normalizeStore`, its rows linked before `row`. */
	function normalizeStore(block:Int, row:Int, value:IrValueId, field:IrObjectField):IrValueId {
		var provenance = body.provenance(row),
			native = IrFieldStorage.scalar(field),
			width = native == null ? 0 : native.size,
			type = body.valueType(value),
			bits = switch type {
				case I32: 32;
				case I64: 64;
				default: 0;
			};
		if (native != null && bits > 0 && width > 0 && width * 8 < bits) {
			var typeId = body.valueTypeId(value),
				shift = body.newValue("$scalar-shift", body.typeId(I32)),
				shifted = body.newValue("$scalar-truncate", typeId),
				result = body.newValue("$scalar-extend", typeId);
			body.beginRow();
			body.linkBefore(block, row, body.endRow(IrOpcode.ConstInt, shift, bits - width * 8, provenance));
			body.beginRow();
			body.pushOperand(value);
			body.pushOperand(shift);
			body.linkBefore(block, row, body.endRow(IrOpcode.ShiftLeft, shifted, 0, provenance));
			body.beginRow();
			body.pushOperand(shifted);
			body.pushOperand(shift);
			body.linkBefore(block, row,
				body.endRow(native.signed ? IrOpcode.ShiftRight : IrOpcode.UnsignedShiftRight, result, 0, provenance));
			return result;
		}
		switch type {
			case F32:
				var wide = body.newValue("$scalar-f64", body.typeId(F64)),
					result = body.newValue("$scalar-f32", body.typeId(F32));
				body.beginRow();
				body.pushOperand(value);
				body.linkBefore(block, row, body.endRow(IrOpcode.FloatToFloat, wide, 0, provenance));
				body.beginRow();
				body.pushOperand(wide);
				body.linkBefore(block, row, body.endRow(IrOpcode.FloatToFloat, result, 0, provenance));
				return result;
			default:
				return value;
		}
	}

	/** `IrScalarReplacement.constructInPlace`. */
	function constructInPlace():Bool {
		var stored = this.stored, changed = false;
		stored.clear();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.FieldSet)
					stored.add(body.operand(row, 1));
				row = body.nextRow(row);
			}
		}
		for (block in 0...body.blockCount()) {
			// A replacement can add phis at the block's start, so the walk goes on from the same position, as a number.
			var position = 0, row = body.firstRow(block);
			while (row >= 0 && !body.opcode(row).isTerminator()) {
				if (body.opcode(row) == IrOpcode.ValueInit) {
					var object = body.output(row),
						typeName = IrTypeTools.valueObjectName(body.valueType(object)),
						descriptor = objects.get(typeName);
					if (descriptor != null && descriptor.isValue && stored.has(object)) {
						if (nested.constructInPlace(this, object, typeName, block, row))
							changed = true;
						if (body.definingRow(object) < 0) {
							row = rowAt(block, position);
							continue;
						}
						if (!IrScalarReplacement.hasValueField(descriptor, objects) && storeOnly(block, row, object)
							&& IrScalarReplacement.parentSlotTypeIsInline(body.valueType(storeDestination),
							IrSymbol.at(storeField).name, typeName, objects)) {
							placeInSlot(block, row, object, descriptor);
							changed = true;
							row = rowAt(block, position);
							continue;
						}
					}
				}
				position++;
				row = body.nextRow(row);
			}
		}
		return changed;
	}

	/** The row at `position` in block `block`, or -1 past its last. */
	function rowAt(block:Int, position:Int):Int {
		var row = body.firstRow(block);
		while (row >= 0 && position-- > 0)
			row = body.nextRow(row);
		return row;
	}

	/** `IrScalarReplacement.storeOnly`: the store in `storeRow`, `storeDestination` and `storeField`. */
	function storeOnly(home:Int, allocation:Int, object:IrValueId):Bool {
		var found = -1;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), after = false;
			while (row >= 0) {
				var opcode = body.opcode(row), count = body.operandCount(row);
				if (opcode.isTerminator()) {
					if (count > 0 && body.operand(row, 0) == object)
						return false;
				} else if (opcode == IrOpcode.Phi) {
					for (index in 0...count)
						if (body.operand(row, index) == object)
							return false;
				} else {
					var uses = 0;
					for (index in 0...count)
						if (body.operand(row, index) == object)
							uses++;
					if (uses > 0) {
						if (block != home || !after || opcode != IrOpcode.FieldSet)
							return false;
						var target = body.operand(row, 0), value = body.operand(row, 1);
						if (target == object && value != object) {} else if (value == object && target != object
							&& uses == 1 && found < 0) {
							found = row;
							storeDestination = target;
							storeField = body.aux(row);
						} else
							return false;
					}
				}
				if (row == allocation)
					after = true;
				row = body.nextRow(row);
			}
		}
		if (found < 0)
			return false;
		// Every write to the new instance must come before the store, or the copy would have missed it.
		var row = body.nextRow(found);
		while (row >= 0) {
			if (body.opcode(row) == IrOpcode.FieldSet && body.operand(row, 0) == object)
				return false;
			row = body.nextRow(row);
		}
		storeRow = found;
		return true;
	}

	/** `IrScalarReplacement.placeInSlot`. */
	function placeInSlot(block:Int, allocation:Int, object:IrValueId, descriptor:IrObject):Void {
		var fields = descriptor.fields, store = storeRow;
		setFields(descriptor);
		IrPassScratch.filledInts(written, fields.length, -1);
		// The latest write to each field before the store is the value the copy would have carried.
		var row = body.nextRow(allocation);
		while (row != store) {
			if (body.opcode(row) == IrOpcode.FieldSet && body.operand(row, 0) == object) {
				var field = fieldIndex(body.aux(row));
				if (field >= 0)
					written[field] = body.operand(row, 1);
			}
			row = body.nextRow(row);
		}
		var provenance = body.provenance(store);
		var slot = body.newValue(IrSymbol.at(storeField).name, body.typeId(Obj(descriptor.name)));
		body.beginRow();
		body.pushOperand(storeDestination);
		body.linkBefore(block, store, body.endRow(IrOpcode.FieldGet, slot, storeField, provenance));
		var objectName = body.valueName(object);
		for (index in 0...fields.length) {
			var field = fields[index], value = written[index];
			if (value < 0) {
				value = body.newValue(objectName + "." + field.name, body.typeId(field.type));
				body.linkBefore(block, store, zeroRow(body, IrValueId.of(value), field.type, provenance));
			}
			body.beginRow();
			body.pushOperand(slot);
			body.pushOperand(IrValueId.of(value));
			body.linkBefore(block, store,
				body.endRow(IrOpcode.FieldSet, IrValueId.of(-1), fieldSymbols[index], provenance));
		}
		row = body.nextRow(allocation);
		body.removeRow(block, allocation);
		while (row != store) {
			var next = body.nextRow(row);
			if (body.opcode(row) == IrOpcode.FieldSet && body.operand(row, 0) == object)
				body.removeRow(block, row);
			row = next;
		}
		body.removeRow(block, store);
	}
}
