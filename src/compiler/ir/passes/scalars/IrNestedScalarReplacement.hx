package compiler.ir.passes.scalars;

import compiler.ir.model.IrPassScratch.IrValueMarks;
import compiler.ir.model.IrBody;
import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.model.IrFunction;
import compiler.ir.cfg.IrGraph;
import compiler.ir.passes.values.IrInlineValueLayout;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrOperands;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;
import compiler.ir.model.SourceProvenance;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.model.SourceProvenance.Located;
import compiler.ir.passes.scalars.IrScalarReplacement.IrBodyScalarReplacement;
import compiler.ir.passes.values.IrInlineValueLayout.IrInlineValueSlot;

private typedef NestedAlias = {
	final path:Array<String>;
	final typeName:String;
}

/** Scalar-replace a non-escaping value and recursively inline its value fields into independent SSA fields. */
@:allow(compiler.ir.passes.scalars.IrBodyNestedScalarReplacement)
class IrNestedScalarReplacement {
	/** Expand copies of a fresh value into inline fields, snapshot their leaves, and scalar-replace the source.
	 * Publish the expansion only when all uses can be replaced; genuine escapes keep their original ABI.
	 */
	public static function constructInPlace(blocks:Array<IrBlock>, objects:IrObjectTable, root:IrValue, typeName:String,
			home:IrBlock,
			position:Int, substitutions:Map<Int, IrValue>, nextValue:Int):Int {
		if (!hasFiniteKnownLayout(typeName, objects, [])) return nextValue;
		var stores = 0;
		for (block in blocks) for (located in block.instructions) switch located.value {
			case FieldSet(target, field, value) if (value.id == root.id && target.id != root.id):
				if (!IrScalarReplacement.parentSlotIsInline(target, field, typeName, objects)) return nextValue;
				stores++;
			default:
		}
		if (stores == 0) return nextValue;
		var slots = new IrInlineValueLayout(objects).slots(Obj(typeName));
		for (slot in slots) if (slot.isPresence) return nextValue;
		var copies:Array<IrBlock> = [], next = nextValue, copiedHome:Null<IrBlock> = null;
		for (block in blocks) {
			var copy = new IrBlock(block.id);
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index];
				var destination:Null<IrValue> = null, field:Null<String> = null;
				switch located.value {
					case FieldSet(target, name, value) if (value.id == root.id && target.id != root.id):
						destination = target;
						field = name;
					default:
				}
				if (destination == null || field == null) {
					copy.instructions.push(located);
					continue;
				}
				var target = new IrValue(next++, field, Obj(typeName));
				copy.instructions.push(new Located(FieldGet(target, destination, field), located.provenance));
				var pending:Array<{target:IrValue, field:String, value:IrValue}> = [];
				for (slot in slots) {
					var source = root, dest = target, owner = typeName;
					for (partIndex in 0...slot.path.length) {
						var part = slot.path[partIndex], declared = findField(objects, owner, part);
						if (declared == null) return nextValue;
						var value = new IrValue(next++, part, declared.type);
						copy.instructions.push(new Located(FieldGet(value, source, part), located.provenance));
						if (partIndex == slot.path.length - 1) pending.push({target: dest, field: part, value: value});
						else {
							var nested = valueName(declared.type, objects);
							if (nested == null) return nextValue;
							var child = new IrValue(next++, part, declared.type);
							copy.instructions.push(new Located(FieldGet(child, dest, part), located.provenance));
							source = value;
							dest = child;
							owner = nested;
						}
					}
				}
				for (entry in pending) copy.instructions
					.push(new Located(FieldSet(entry.target, entry.field, entry.value), located.provenance));
			}
			copy.terminator = block.terminator;
			copies.push(copy);
			if (block == home) copiedHome = copy;
		}
		if (copiedHome == null) return nextValue;
		var local:Map<Int, IrValue> = [for (id => value in substitutions) id => value];
		// Restrict this transformation to one block in functions with handlers, as in the ordinary pass.
		var handlers = false;
		for (block in copies) for (located in block.instructions) switch located.value {
			case BeginTry(_, _, _), EndTry(_, _), Catch(_): handlers = true;
			default:
		}
		var result = tryReplace(copies, objects, root, typeName, copiedHome, position, handlers, local, next);
		if (IrScalarReplacement.allocationPosition(copiedHome, root) >= 0) return nextValue;
		for (index in 0...blocks.length) {
			blocks[index].instructions.resize(0);
			for (located in copies[index].instructions) blocks[index].instructions.push(located);
		}
		for (id => value in local) substitutions.set(id, value);
		return result;
	}

	public static function tryReplace(blocks:Array<IrBlock>, objects:IrObjectTable, root:IrValue, typeName:String,
			home:IrBlock,
			position:Int, hasHandlers:Bool, substitutions:Map<Int, IrValue>, nextValue:Int, forcePhis = false):Int {
		if (!hasFiniteKnownLayout(typeName, objects, [])) return nextValue;
		var aliases:Map<Int, NestedAlias> = [root.id => {
			path:[], typeName:typeName
		}], changed = true;
		while (changed) {
			changed = false;
			for (block in blocks)
				for (located in block.instructions)
					switch located.value {
						case FieldGet(out, object, field) if (aliases.exists(object.id) && !aliases.exists(out.id)):
							var parent = aliases.get(object.id), declared = findField(objects, parent.typeName, field);
							if (declared == null) return nextValue;
							var nested = valueName(declared.type, objects);
							if (nested != null) {
								aliases.set(out.id, {path: parent.path.concat([field]), typeName: nested});
								changed = true;
							}
						default:
					}
		}
		var graph = new IrGraph(new IrFunction("nested-scalar-check", [], Void, blocks, Ordinary));
		if (!onlyFieldUses(blocks, aliases, home, position,
			hasHandlers && !unchangedAfterHandlers(blocks, aliases, home, graph), graph)) return nextValue;
		var layout = new IrInlineValueLayout(objects),
			slots = layout.slots(Obj(typeName)),
			fields:Array<IrObjectField> = [];
		for (slot in slots) {
			if (slot.isPresence) return nextValue;
			fields.push({
				name: slotName(slot.path),
				type: slot.type,
				nativeLayout: slot.nativeLayout,
				scalarStorage: slot.scalarStorage,
				nullableScalarStorage: slot.nullableScalarStorage
			});
		}
		var descriptor:IrObject = {
			name: typeName,
			isValue: true,
			base: null,
			interfaces: [],
			fields: fields,
			methods: []
		};
		var copies:Array<IrBlock> = [], next = nextValue;
		for (block in blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case FieldGet(out, object, field) if (aliases.exists(object.id)):
						var alias = aliases.get(object.id), path = alias.path.concat([field]);
						if (!aliases.exists(out.id)) copy.instructions
							.push(new Located(FieldGet(out, root, slotName(path)), located.provenance));
					case FieldSet(object, field, value) if (aliases.exists(object.id)):
						var alias = aliases.get(object.id),
							path = alias.path.concat([field]),
							declared = findField(objects, alias.typeName, field);
						if (declared == null) return nextValue;
						var nested = valueName(declared.type, objects);
						if (nested == null) {
							var slot = findSlot(slots, path);
							if (slot == null) return nextValue;
							copy.instructions.push(new Located(FieldSet(root, slotName(path), value),
								located.provenance));
						}
							else {
							// Snapshot every leaf before writing any destination leaf, including overlapping source and destination.
							var values:Array<{name:String, value:IrValue}> = [];
							for (slot in slots) if (startsWith(slot.path, path)) {
								var relative = slot.path.slice(path.length),
									source = aliases.get(value.id),
									leaf:IrValue;
								if (source != null) {
									leaf = new IrValue(next++, value.name + ".field", slot.type);
									copy.instructions.push(new Located(FieldGet(leaf, root,
										slotName(source.path.concat(relative))), located.provenance));
								} else {
									var current = value, currentName = nested;
									for (part in relative) {
										var component = findField(objects, currentName, part);
										if (component == null) return nextValue;
										var loaded = new IrValue(next++, value.name + "." + part, component.type);
										copy.instructions.push(new Located(FieldGet(loaded, current, part),
											located.provenance));
										current = loaded;
										var child = valueName(component.type, objects);
										if (child != null) currentName = child;
									}
									leaf = current;
								}
								values.push({name: slotName(slot.path), value: leaf});
							}
							for (entry in values) copy.instructions
								.push(new Located(FieldSet(root, entry.name, entry.value), located.provenance));
						}
					default: copy.instructions.push(located);
				}
			}
			copy.terminator = block.terminator;
			copies.push(copy);
		}
		var copiedHome:Null<IrBlock> = null;
		for (block in copies) if (block.id == home.id) copiedHome = block;
		if (copiedHome == null) throw new InternalError("Missing nested scalar replacement block");
		var copiedPosition = IrScalarReplacement.allocationPosition(copiedHome, root);
		if (copiedPosition < 0) return nextValue;
		var copiedGraph = new IrGraph(new IrFunction("nested-scalar-replacement", [], Void, copies, Ordinary)),
			localSubstitutions:Map<Int, IrValue> = [for (id => value in substitutions) id => value],
			result = IrScalarReplacement.replace(copies, copiedGraph,
				IrScalarReplacement.dominanceFrontiers(copiedGraph),
				IrScalarReplacement.dominatorChildren(copiedGraph), {
					object: root,
					typeName: typeName,
					block: copiedHome,
					position: copiedPosition
				},
				descriptor, localSubstitutions, next, forcePhis);
		// The scalar pass can decline an unprofitable phi. Do not publish the temporary flattened form then.
		if (IrScalarReplacement.allocationPosition(copiedHome, root) >= 0) return nextValue;
		for (index in 0...blocks.length) {
			blocks[index].instructions.resize(0);
			for (located in copies[index].instructions) blocks[index].instructions.push(located);
		}
		for (id => value in localSubstitutions) substitutions.set(id, value);
		return result;
	}

	/** Values initialized before any handler and not changed afterwards have the same
	 * field definitions on normal and exceptional edges. Stop at the allocation block:
	 * a later loop iteration initializes a distinct value. */
	static function unchangedAfterHandlers(blocks:Array<IrBlock>, aliases:Map<Int, NestedAlias>, home:IrBlock,
			graph:IrGraph):Bool {
		var writes:Map<Int, Array<Int>> = [], handlers:Array<{block:Int, position:Int}> = [];
		for (block in blocks) for (position in 0...block.instructions.length) {
			var instruction = block.instructions[position].value;
			for (input in IrOperands.inputs(instruction)) if (aliases.exists(input.id)
				&& !graph.dominates(home.id, block.id)) return false;
			switch instruction {
				case FieldSet(target, _, _) if (aliases.exists(target.id)):
					if (!writes.exists(block.id)) writes.set(block.id, []);
					writes.get(block.id).push(position);
				case BeginTry(_, _, _): handlers.push({block: block.id, position: position});
				default:
			}
		}
		for (handler in handlers) {
			var local = writes.get(handler.block);
			if (local != null) for (position in local) if (position > handler.position) return false;
			var seen:Map<Int, Bool> = [], pending:Array<Int> = [];
			if (graph.isReachable(handler.block))
				for (index in 0...graph.successorCount(handler.block)) pending.push(graph.successor(handler.block,
					index));
			while (true) {
				var id = pending.pop();
				if (id == null)
					break;
				if (id == home.id || seen.exists(id)) continue;
				seen.set(id, true);
				if (writes.exists(id)) return false;
				if (graph.isReachable(id))
					for (index in 0...graph.successorCount(id)) pending.push(graph.successor(id, index));
			}
		}
		return true;
	}

	static function onlyFieldUses(blocks:Array<IrBlock>, aliases:Map<Int, NestedAlias>, home:IrBlock, allocation:Int,
			singleBlock:Bool,
			graph:IrGraph):Bool {
		for (block in blocks) {
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				switch instruction {
					case Phi(_, inputs): for (input in inputs) if (aliases.exists(input.value.id)) return false;
					default:
				}
				var touches = false;
				for (input in IrOperands.inputs(instruction)) if (aliases.exists(input.id)) touches = true;
				if (!touches) continue;
				if (block == home ? position <= allocation : singleBlock
					|| !graph.contains(block.id)) return false;
				switch instruction {
					case FieldGet(_, target, _) if (aliases.exists(target.id)):
					case FieldSet(target, _, value) if (aliases.exists(target.id)):
					default: return false;
				}
			}
			var terminator = block.terminator;
			if (terminator != null) switch terminator.value {
				case Return(value), Throw(value), Rethrow(value),
					Branch(value, _, _) if (aliases.exists(value.id)): return false;
				default:
			}
		}
		return true;
	}

	static function hasFiniteKnownLayout(name:String, objects:IrObjectTable, visiting:Array<String>):Bool {
		if (visiting.indexOf(name) >= 0) return false;
		var object = objects.get(name);
		if (object == null || !object.isValue) return false;
		for (field in object.fields) switch field.type {
			case Obj(child):
				var nested = objects.get(child);
				if (nested == null
					|| (nested.isValue && !hasFiniteKnownLayout(child, objects, visiting.concat([name])))) return false;
			case Nullable(Obj(child)):
				var nested = objects.get(child);
				if (nested == null || nested.isValue) return false;
			default:
		}
		return true;
	}

	static function findField(objects:IrObjectTable, owner:String, name:String):Null<IrObjectField> {
		var object = objects.get(owner);
		if (object == null) return null;
		for (field in object.fields) if (field.name == name) return field;
		return null;
	}

	static function valueName(type:IrType, objects:IrObjectTable):Null<String>
		return switch type {
			case Obj(name): var object = objects.get(name);
				object != null && object.isValue ? name : null;
			default: null;
		};

	static function startsWith(path:Array<String>, prefix:Array<String>):Bool {
		if (path.length < prefix.length) return false;
		for (index in 0...prefix.length) if (path[index] != prefix[index]) return false;
		return true;
	}

	static function findSlot(slots:Array<IrInlineValueSlot>, path:Array<String>):Null<IrInlineValueSlot> {
		for (slot in slots)
			if (!slot.isPresence && slot.path.length == path.length && startsWith(slot.path, path)) return slot;
		return null;
	}

	static function slotName(path:Array<String>):String
		return IrInlineValueLayout.slotName("scalar", {path: path, type: Void, isPresence: false, nativeLayout: null});
}

/**
 * `IrNestedScalarReplacement` on a body, in place, with the same result. The object version rewrites copies of the blocks and
 * keeps them only when the replacement goes through; this rewrites the body in a trial (`IrBody.beginTrial`) and rolls it back
 * when it does not.
 */
@:allow(compiler.ir.passes.scalars.IrBodyScalarReplacement)
class IrBodyNestedScalarReplacement {
	/** The values that are the root or a value field of it, with the path of each from the root and its type's name. */
	final aliased = new IrValueMarks();

	final aliasPaths:Array<Null<Array<String>>> = [];
	final aliasTypes:Array<Null<String>> = [];
	final aliasIds:Array<Int> = [];

	/** Per block id, the position of its last write to an alias, or -1. */
	final lastWrites:Array<Int> = [];

	/** `BeginTry` rows as (block id, position) pairs. */
	final handlers:Array<Int> = [];

	final seen:Array<Int> = [];
	var stamp = 0;
	final work:Array<Int> = [];

	/** Stores a copy makes: (destination, field symbol, value) triples. */
	final pending:Array<Int> = [];

	/** The leaves a nested store writes: slot names and values. */
	final leafNames:Array<String> = [];

	final leafValues:Array<Int> = [];

	public function new() {}

	/** Drops what the tables hold of the last function. */
	function release():Void {
		for (id in aliasIds) {
			aliasPaths[id] = null;
			aliasTypes[id] = null;
		}
		aliasIds.resize(0);
		leafNames.resize(0);
	}

	/** `IrNestedScalarReplacement.constructInPlace`; whether the copies of `root` were expanded and `root` replaced. */
	function constructInPlace(pass:IrBodyScalarReplacement, root:IrValueId, typeName:String, home:Int,
			allocation:Int):Bool {
		var body = pass.body, objects = pass.objects;
		if (!IrNestedScalarReplacement.hasFiniteKnownLayout(typeName, objects, []))
			return false;
		var stores = 0;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.FieldSet && body.operand(row, 1) == root
					&& body.operand(row, 0) != root) {
					if (!IrScalarReplacement.parentSlotTypeIsInline(body.valueType(body.operand(row, 0)),
						IrSymbol.at(body.aux(row)).name, typeName, objects))
						return false;
					stores++;
				}
				row = body.nextRow(row);
			}
		}
		if (stores == 0)
			return false;
		var slots = new IrInlineValueLayout(objects).slots(Obj(typeName));
		for (slot in slots)
			if (slot.isPresence)
				return false;
		body.beginTrial(pass.trial);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.FieldSet && body.operand(row, 1) == root
					&& body.operand(row, 0) != root
					&& !expandStore(body, objects, block, row, root, typeName, slots)) {
					body.rollback();
					return false;
				}
				row = next;
			}
		}
		// Restrict this transformation to one block in functions with handlers, as in the ordinary pass.
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
		if (!tryReplace(pass, root, typeName, home, allocation, hasHandlers, false, false)
			|| body.definingRow(root) >= 0) {
			body.rollback();
			return false;
		}
		body.endTrial();
		return true;
	}

	/** Replaces the store `row` of `root` into another value's field by a copy of each of its leaves; false to give up. */
	function expandStore(body:IrBody, objects:IrObjectTable, block:Int, row:Int, root:IrValueId, typeName:String,
			slots:Array<IrInlineValueSlot>):Bool {
		var destination = body.operand(row, 0),
			fieldSymbol = body.aux(row),
			provenance = body.provenance(row),
			target = body.newValue(IrSymbol.at(fieldSymbol).name, body.typeId(Obj(typeName)));
		linkLoad(body, block, row, target, destination, fieldSymbol, provenance);
		pending.resize(0);
		for (slot in slots) {
			var source = root, destination = target, owner = typeName;
			for (partIndex in 0...slot.path.length) {
				var part = slot.path[partIndex], declared = IrNestedScalarReplacement.findField(objects, owner, part);
				if (declared == null)
					return false;
				var partSymbol = IrSymbol.of(part).id, value = body.newValue(part, body.typeId(declared.type));
				linkLoad(body, block, row, value, source, partSymbol, provenance);
				if (partIndex == slot.path.length - 1) {
					pending.push(destination);
					pending.push(partSymbol);
					pending.push(value);
				} else {
					var nested = IrNestedScalarReplacement.valueName(declared.type, objects);
					if (nested == null)
						return false;
					var child = body.newValue(part, body.typeId(declared.type));
					linkLoad(body, block, row, child, destination, partSymbol, provenance);
					source = value;
					destination = child;
					owner = nested;
				}
			}
		}
		for (entry in 0...Std.int(pending.length / 3))
			linkStore(body, block, row, IrValueId.of(pending[entry * 3]), pending[entry * 3 + 1],
				IrValueId.of(pending[entry * 3 + 2]), provenance);
		body.removeRow(block, row);
		return true;
	}

	static function linkLoad(body:IrBody, block:Int, before:Int, output:IrValueId, object:IrValueId, field:Int,
			provenance:SourceProvenance):Void {
		body.beginRow();
		body.pushOperand(object);
		body.linkBefore(block, before, body.endRow(IrOpcode.FieldGet, output, field, provenance));
	}

	static function linkStore(body:IrBody, block:Int, before:Int, object:IrValueId, field:Int, value:IrValueId,
			provenance:SourceProvenance):Void {
		body.beginRow();
		body.pushOperand(object);
		body.pushOperand(value);
		body.linkBefore(block, before, body.endRow(IrOpcode.FieldSet, IrValueId.of(-1), field, provenance));
	}

	function addAlias(value:IrValueId, path:Array<String>, typeName:String):Void {
		aliased.add(value);
		while (aliasPaths.length <= (value:Int)) {
			aliasPaths.push(null);
			aliasTypes.push(null);
		}
		aliasPaths[value] = path;
		aliasTypes[value] = typeName;
		aliasIds.push(value);
	}

	/**
	 * `IrNestedScalarReplacement.tryReplace`; whether `root` was replaced. In its own trial when `ownTrial`, else in the
	 * caller's, which the caller rolls back when this gives up.
	 */
	function tryReplace(pass:IrBodyScalarReplacement, root:IrValueId, typeName:String, home:Int, allocation:Int,
			hasHandlers:Bool, forcePhis:Bool, ownTrial:Bool):Bool {
		var body = pass.body, objects = pass.objects;
		if (!IrNestedScalarReplacement.hasFiniteKnownLayout(typeName, objects, []))
			return false;
		release();
		aliased.clear();
		addAlias(root, [], typeName);
		var changed = true;
		while (changed) {
			changed = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.FieldGet && aliased.has(body.operand(row, 0))
						&& !aliased.has(body.output(row))) {
						var object = body.operand(row, 0),
							field = IrSymbol.at(body.aux(row)).name,
							declared = IrNestedScalarReplacement.findField(objects, aliasTypes[object], field);
						if (declared == null)
							return false;
						var nested = IrNestedScalarReplacement.valueName(declared.type, objects);
						if (nested != null) {
							addAlias(body.output(row), aliasPaths[object].concat([field]), nested);
							changed = true;
						}
					}
					row = body.nextRow(row);
				}
			}
		}
		var graph = pass.prepareGraph();
		if (!onlyFieldUses(body, graph, home, allocation,
			hasHandlers && !unchangedAfterHandlers(body, graph, home)))
			return false;
		var slots = new IrInlineValueLayout(objects).slots(Obj(typeName)),
			fields:Array<IrObjectField> = [];
		for (slot in slots) {
			if (slot.isPresence)
				return false;
			fields.push({
				name: IrNestedScalarReplacement.slotName(slot.path),
				type: slot.type,
				nativeLayout: slot.nativeLayout,
				scalarStorage: slot.scalarStorage,
				nullableScalarStorage: slot.nullableScalarStorage
			});
		}
		var descriptor:IrObject = {
			name: typeName,
			isValue: true,
			base: null,
			interfaces: [],
			fields: fields,
			methods: []
		};
		if (ownTrial)
			body.beginTrial(pass.trial);
		if (!flatten(body, objects, root, slots)
			|| !pass.replace(root, typeName, home, allocation, descriptor, forcePhis)) {
			if (ownTrial)
				body.rollback();
			return false;
		}
		if (ownTrial)
			body.endTrial();
		return true;
	}

	/** Rewrites every access through an alias as an access to the root's slot; false to give up. */
	function flatten(body:IrBody, objects:IrObjectTable, root:IrValueId, slots:Array<IrInlineValueSlot>):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row), opcode = body.opcode(row);
				if ((opcode == IrOpcode.FieldGet || opcode == IrOpcode.FieldSet) && aliased.has(body.operand(row, 0))) {
					var object = body.operand(row, 0),
						provenance = body.provenance(row),
						field = IrSymbol.at(body.aux(row)).name,
						path = aliasPaths[object].concat([field]);
					if (opcode == IrOpcode.FieldGet) {
						var out = body.output(row);
						if (!aliased.has(out))
							linkLoad(body, block, row, out, root, slotSymbol(path), provenance);
					} else {
						var value = body.operand(row, 1),
							declared = IrNestedScalarReplacement.findField(objects, aliasTypes[object], field);
						if (declared == null)
							return false;
						var nested = IrNestedScalarReplacement.valueName(declared.type, objects);
						if (nested == null) {
							if (IrNestedScalarReplacement.findSlot(slots, path) == null)
								return false;
							linkStore(body, block, row, root, slotSymbol(path), value, provenance);
						} else if (!snapshot(body, objects, block, row, root, slots, path, value, nested, provenance))
							return false;
					}
					body.removeRow(block, row);
				}
				row = next;
			}
		}
		return true;
	}

	/** Reads every leaf of `value` under `path` before writing any, as source and destination may overlap. */
	function snapshot(body:IrBody, objects:IrObjectTable, block:Int, row:Int, root:IrValueId,
			slots:Array<IrInlineValueSlot>, path:Array<String>, value:IrValueId, nested:String,
			provenance:SourceProvenance):Bool {
		leafNames.resize(0);
		leafValues.resize(0);
		for (slot in slots)
			if (IrNestedScalarReplacement.startsWith(slot.path, path)) {
				var relative = slot.path.slice(path.length), leaf:IrValueId;
				if (aliased.has(value)) {
					leaf = body.newValue(body.valueName(value) + ".field", body.typeId(slot.type));
					linkLoad(body, block, row, leaf, root, slotSymbol(aliasPaths[value].concat(relative)), provenance);
				} else {
					var current = value, currentName = nested;
					for (part in relative) {
						var component = IrNestedScalarReplacement.findField(objects, currentName, part);
						if (component == null)
							return false;
						var loaded = body.newValue(body.valueName(value) + "." + part, body.typeId(component.type));
						linkLoad(body, block, row, loaded, current, IrSymbol.of(part).id, provenance);
						current = loaded;
						var child = IrNestedScalarReplacement.valueName(component.type, objects);
						if (child != null)
							currentName = child;
					}
					leaf = current;
				}
				leafNames.push(IrNestedScalarReplacement.slotName(slot.path));
				leafValues.push(leaf);
			}
		for (index in 0...leafNames.length)
			linkStore(body, block, row, root, IrSymbol.of(leafNames[index]).id, IrValueId.of(leafValues[index]),
				provenance);
		return true;
	}

	static function slotSymbol(path:Array<String>):Int
		return IrSymbol.of(IrNestedScalarReplacement.slotName(path)).id;

	/** `IrNestedScalarReplacement.unchangedAfterHandlers`, positions counted within each block. */
	function unchangedAfterHandlers(body:IrBody, graph:IrBodyGraph, home:Int):Bool {
		var homeId = body.blockId(home), size = 0;
		for (block in 0...body.blockCount())
			if (body.blockId(block) >= size)
				size = body.blockId(block) + 1;
		IrPassScratch.filledInts(lastWrites, size, -1);
		while (seen.length < size)
			seen.push(0);
		handlers.resize(0);
		for (block in 0...body.blockCount()) {
			var id = body.blockId(block), row = body.firstRow(block), position = 0;
			while (row >= 0 && !body.opcode(row).isTerminator()) {
				var opcode = body.opcode(row);
				if (opcode != IrOpcode.Phi)
					for (index in 0...body.operandCount(row))
						if (aliased.has(body.operand(row, index)) && !graph.dominates(homeId, id))
							return false;
				if (opcode == IrOpcode.FieldSet && aliased.has(body.operand(row, 0)))
					lastWrites[id] = position;
				else if (opcode == IrOpcode.BeginTry) {
					handlers.push(id);
					handlers.push(position);
				}
				position++;
				row = body.nextRow(row);
			}
		}
		for (handler in 0...Std.int(handlers.length / 2)) {
			var block = handlers[handler * 2], position = handlers[handler * 2 + 1];
			if (lastWrites[block] > position)
				return false;
			var mark = ++stamp;
			work.resize(0);
			if (graph.isReachable(block))
				for (index in 0...graph.successorCount(block))
					work.push(graph.successor(block, index));
			while (work.length > 0) {
				var id = work.pop();
				if (id == homeId || seen[id] == mark)
					continue;
				seen[id] = mark;
				if (lastWrites[id] >= 0)
					return false;
				if (graph.isReachable(id))
					for (index in 0...graph.successorCount(id))
						work.push(graph.successor(id, index));
			}
		}
		return true;
	}

	/** `IrNestedScalarReplacement.onlyFieldUses`: rows up to the allocation in its block count as before it. */
	function onlyFieldUses(body:IrBody, graph:IrBodyGraph, home:Int, allocation:Int, singleBlock:Bool):Bool {
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), after = false;
			while (row >= 0) {
				var opcode = body.opcode(row), count = body.operandCount(row);
				switch opcode {
					case IrOpcode.Return, IrOpcode.Throw, IrOpcode.Rethrow, IrOpcode.Branch:
						if (aliased.has(body.operand(row, 0)))
							return false;
					case IrOpcode.Phi:
						for (index in 0...count)
							if (aliased.has(body.operand(row, index)))
								return false;
					case _ if (opcode.isTerminator()):
					default:
						var touches = false;
						for (index in 0...count)
							if (aliased.has(body.operand(row, index)))
								touches = true;
						if (touches) {
							if (block == home ? !after : singleBlock || !graph.contains(body.blockId(block)))
								return false;
							if ((opcode != IrOpcode.FieldGet && opcode != IrOpcode.FieldSet)
								|| !aliased.has(body.operand(row, 0)))
								return false;
						}
				}
				if (row == allocation)
					after = true;
				row = body.nextRow(row);
			}
		}
		return true;
	}
}
