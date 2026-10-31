package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.SourceProvenance.Located;

private typedef NestedAlias = {final path:Array<String>; final typeName:String;}

/** Scalar-replace a non-escaping value and recursively inline its value fields into independent SSA fields. */
class IrNestedScalarReplacement {
	/** Expand a final inline-field copy into leaf reads and writes, then scalar-replace its source. */
	public static function constructInPlace(blocks:Array<IrBlock>, objects:IrObjectTable, root:IrValue, typeName:String, home:IrBlock,
			position:Int, substitutions:Map<Int, IrValue>, nextValue:Int):Int {
		if (!hasFiniteKnownLayout(typeName, objects, [])) return nextValue;
		var store = -1, destination:Null<IrValue> = null, field:Null<String> = null;
		for (block in blocks) for (index in 0...block.instructions.length) switch block.instructions[index].value {
			case FieldSet(target, name, value) if (value.id == root.id && target.id != root.id):
				if (block != home || index <= position || store >= 0 || !IrScalarReplacement.parentSlotIsInline(target, name, typeName, objects)) return nextValue;
				store = index; destination = target; field = name;
			default:
		}
		if (store < 0 || destination == null || field == null) return nextValue;
		var slots = new IrInlineValueLayout(objects).slots(Obj(typeName));
		for (slot in slots) if (slot.isPresence) return nextValue;
		var copies:Array<IrBlock> = [], next = nextValue, copiedHome:Null<IrBlock> = null;
		for (block in blocks) {
			var copy = new IrBlock(block.id);
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index];
				if (block != home || index != store) { copy.instructions.push(located); continue; }
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
							source = value; dest = child; owner = nested;
						}
					}
				}
				for (entry in pending) copy.instructions.push(new Located(FieldSet(entry.target, entry.field, entry.value), located.provenance));
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
			case BeginTry(_, _), EndTry(_), Catch(_): handlers = true;
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

	public static function tryReplace(blocks:Array<IrBlock>, objects:IrObjectTable, root:IrValue, typeName:String, home:IrBlock,
			position:Int, hasHandlers:Bool, substitutions:Map<Int, IrValue>, nextValue:Int):Int {
		if (!hasFiniteKnownLayout(typeName, objects, [])) return nextValue;
		var aliases:Map<Int, NestedAlias> = [root.id => {path: [], typeName: typeName}], changed = true;
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
		var graph = new IrGraph(new IrFunction("nested-scalar-check", [], Void, blocks));
		if (!onlyFieldUses(blocks, aliases, home, position, hasHandlers, graph)) return nextValue;
		var layout = new IrInlineValueLayout(objects), slots = layout.slots(Obj(typeName)), fields:Array<IrObjectField> = [];
		for (slot in slots) {
			if (slot.isPresence) return nextValue;
			fields.push({name: slotName(slot.path), type: slot.type, nativeLayout: null});
		}
		var descriptor:IrObject = {name: typeName, isValue: true, base: null, interfaces: [], fields: fields, methods: []};
		var copies:Array<IrBlock> = [], next = nextValue;
		for (block in blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = located.value;
				switch instruction {
					case FieldGet(out, object, field) if (aliases.exists(object.id)):
						var alias = aliases.get(object.id), path = alias.path.concat([field]);
						if (!aliases.exists(out.id)) copy.instructions.push(new Located(FieldGet(out, root, slotName(path)), located.provenance));
					case FieldSet(object, field, value) if (aliases.exists(object.id)):
						var alias = aliases.get(object.id), path = alias.path.concat([field]), declared = findField(objects, alias.typeName, field);
						if (declared == null) return nextValue;
						var nested = valueName(declared.type, objects);
						if (nested == null) {
							var slot = findSlot(slots, path);
							if (slot == null) return nextValue;
							var normalized = normalizeStore(copy, value, slot, located, next);
							next = normalized.next;
							copy.instructions.push(new Located(FieldSet(root, slotName(path), normalized.value), located.provenance));
						}
						else {
							// Snapshot every leaf before writing any destination leaf, including overlapping source and destination.
							var values:Array<{name:String, value:IrValue}> = [];
							for (slot in slots) if (startsWith(slot.path, path)) {
								var relative = slot.path.slice(path.length), source = aliases.get(value.id), leaf:IrValue;
								if (source != null) {
									leaf = new IrValue(next++, value.name + ".field", slot.type);
									copy.instructions.push(new Located(FieldGet(leaf, root, slotName(source.path.concat(relative))), located.provenance));
								} else {
									var current = value, currentName = nested;
									for (part in relative) {
										var component = findField(objects, currentName, part);
										if (component == null) return nextValue;
										var loaded = new IrValue(next++, value.name + "." + part, component.type);
										copy.instructions.push(new Located(FieldGet(loaded, current, part), located.provenance));
										current = loaded;
										var child = valueName(component.type, objects);
										if (child != null) currentName = child;
									}
									leaf = current;
								}
								var normalized = normalizeStore(copy, leaf, slot, located, next);
								next = normalized.next;
								values.push({name: slotName(slot.path), value: normalized.value});
							}
							for (entry in values) copy.instructions.push(new Located(FieldSet(root, entry.name, entry.value), located.provenance));
						}
					default: copy.instructions.push(located);
				}
			}
			copy.terminator = block.terminator;
			copies.push(copy);
		}
		var copiedHome:Null<IrBlock> = null;
		for (block in copies) if (block.id == home.id) copiedHome = block;
		if (copiedHome == null) throw "Missing nested scalar replacement block";
		var copiedPosition = IrScalarReplacement.allocationPosition(copiedHome, root);
		if (copiedPosition < 0) return nextValue;
		var copiedGraph = new IrGraph(new IrFunction("nested-scalar-replacement", [], Void, copies)),
			localSubstitutions:Map<Int, IrValue> = [for (id => value in substitutions) id => value],
			result = IrScalarReplacement.replace(copies, copiedGraph, IrScalarReplacement.dominanceFrontiers(copiedGraph),
				IrScalarReplacement.dominatorChildren(copiedGraph), {object: root, typeName: typeName, block: copiedHome, position: copiedPosition},
				descriptor, localSubstitutions, next);
		// The scalar pass can decline an unprofitable phi. Do not publish the temporary flattened form then.
		if (IrScalarReplacement.allocationPosition(copiedHome, root) >= 0) return nextValue;
		for (index in 0...blocks.length) {
			blocks[index].instructions.resize(0);
			for (located in copies[index].instructions) blocks[index].instructions.push(located);
		}
		for (id => value in localSubstitutions) substitutions.set(id, value);
		return result;
	}

	static function onlyFieldUses(blocks:Array<IrBlock>, aliases:Map<Int, NestedAlias>, home:IrBlock, allocation:Int, singleBlock:Bool,
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
				if (block == home ? position <= allocation : singleBlock || !graph.blocks.exists(block.id)) return false;
				switch instruction {
					case FieldGet(_, target, _) if (aliases.exists(target.id)):
					case FieldSet(target, _, value) if (aliases.exists(target.id)):
					default: return false;
				}
			}
			var terminator = block.terminator;
			if (terminator != null) switch terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (aliases.exists(value.id)): return false;
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
				if (nested == null || (nested.isValue && !hasFiniteKnownLayout(child, objects, visiting.concat([name])))) return false;
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
			case Obj(name): var object = objects.get(name); object != null && object.isValue ? name : null;
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

	/** Match the truncation and sign extension a native-width field store and subsequent load perform. */
	static function normalizeStore(block:IrBlock, value:IrValue, slot:IrInlineValueSlot, origin:Located<IrInstruction>,
			next:Int):{value:IrValue, next:Int} {
		var native = slot.nativeLayout, width = native == null ? 0 : native.size,
			bits = switch value.type { case I32: 32; case I64: 64; default: 0; };
		if (native != null && bits > 0 && width > 0 && width * 8 < bits) {
			var shift = new IrValue(next++, "$nested-scalar-shift", I32),
				shifted = new IrValue(next++, "$nested-scalar-truncate", value.type),
				result = new IrValue(next++, "$nested-scalar-extend", value.type);
			block.instructions.push(new Located(ConstInt(shift, bits - width * 8), origin.provenance));
			block.instructions.push(new Located(ShiftLeft(shifted, value, shift), origin.provenance));
			block.instructions.push(new Located(native.signed ? ShiftRight(result, shifted, shift) : UnsignedShiftRight(result, shifted, shift),
				origin.provenance));
			return {value: result, next: next};
		}
		if (value.type == F32) {
			var wide = new IrValue(next++, "$nested-scalar-f64", F64), result = new IrValue(next++, "$nested-scalar-f32", F32);
			block.instructions.push(new Located(FloatToFloat(wide, value), origin.provenance));
			block.instructions.push(new Located(FloatToFloat(result, wide), origin.provenance));
			return {value: result, next: next};
		}
		return {value: value, next: next};
	}

	static function slotName(path:Array<String>):String
		return IrInlineValueLayout.slotName("scalar", {path: path, type: Void, isPresence: false, nativeLayout: null});
}
