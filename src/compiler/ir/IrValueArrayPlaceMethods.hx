package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.codec.IrTypeCodec;

typedef IrValueArrayMethodRequest = {
	final name:String;
	final receiverType:IrType;
	final method:String;
	final path:Array<String>;
}

private typedef ArrayOptionalScalar = {
	final present:IrValue;
	final payload:IrValue;
}

private typedef ArrayFreshField = {
	final value:IrValue;
	final fields:Null<Map<String, ArrayFreshField>>;
	final present:Null<IrValue>;
}

/** Rewrite a value method's receiver as an array and index, keeping each field access on the live place. */
class IrValueArrayPlaceMethods {
	static inline final PREFIX = "$value-array:method:";
	final objects:IrObjectTable;
	final element:IrType;
	final helpers:IrValueArraySlotHelpers;
	public final requests:Array<IrValueArrayMethodRequest> = [];
	final requested:Map<String, Bool> = [];
	final valueWrites:Map<String, {type:IrType, path:Array<String>}> = [];
	final scalarReads:Map<String, {type:IrType, path:Array<String>}> = [];
	var finished = false;

	public function new(objects:IrObjectTable, element:IrType, helpers:IrValueArraySlotHelpers) {
		this.objects = objects;
		this.element = element;
		this.helpers = helpers;
	}

	/** Queue an entry point; nested value calls add their own requests while the queue is generated. */
	public function method(receiverType:IrType, method:String, path:Array<String>):String {
		if (finished) throw "Array place methods have already been generated";
		return request(receiverType, method, path);
	}

	/** Store a separately evaluated struct value into an element projection. */
	public function valueSetter(type:IrType, path:Array<String>):String {
		if (finished || (!isValue(type) && !isNullableScalar(type))) throw "Invalid array place value setter";
		var encoded = haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(haxe.Json.stringify([haxe.crypto.Base64.encode(IrTypeCodec.encode(type)), path]))),
			name = IrValueArrayElements.PREFIX + "place-write:" + encoded + ":" + haxe.crypto.Base64.encode(IrTypeCodec.encode(element));
		if (!valueWrites.exists(name)) valueWrites.set(name, {type: type, path: path.copy()});
		return name;
	}

	/** Read a nullable scalar projection as components after the generated boundary is expanded. */
	public function scalarGetter(type:IrType, path:Array<String>):String {
		if (finished || !isNullableScalar(type)) throw "Invalid array place nullable scalar getter";
		var encoded = haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(haxe.Json.stringify([haxe.crypto.Base64.encode(IrTypeCodec.encode(type)), path]))),
			name = IrValueArrayElements.PREFIX + "place-read:" + encoded + ":" + haxe.crypto.Base64.encode(IrTypeCodec.encode(element));
		if (!scalarReads.exists(name)) scalarReads.set(name, {type: type, path: path.copy()});
		return name;
	}

	public function generate(originals:Map<String, IrFunction>):Array<IrFunction> {
		if (finished) throw "Array place methods have already been generated";
		var result:Array<IrFunction> = [], index = 0;
		while (index < requests.length) {
			var entry = requests[index++], originalName = resolveMethod(entry.receiverType, entry.method, originals),
				original = originals.get(originalName);
			if (original == null) throw 'Missing array place method "$originalName"';
			result.push(specialize(GeneratedHelper, entry.name, original, entry.path));
		}
		var writes = [for (name in valueWrites.keys()) name]; writes.sort(Reflect.compare);
		var bridge = new IrValueArrayBridge(element, element, objects, helpers);
		var reads = [for (name in scalarReads.keys()) name]; reads.sort(Reflect.compare);
		for (name in reads) {
			var request = scalarReads.get(name), builder = new IrBuilder(), array = builder.argument("array", Array(element)),
				position = builder.argument("index", I32);
			builder.call(helpers.checker(request.path, false), [array, position], Void);
			builder.returnValue(bridge.readValue(builder, array, position, request.type, request.path));
			result.push(new IrFunction(name, builder.arguments, request.type, builder.blocks, ValueArrayElement));
		}
		for (name in writes) {
			var request = valueWrites.get(name), builder = new IrBuilder(), array = builder.argument("array", Array(element)),
				position = builder.argument("index", I32), value = builder.argument("value", request.type);
			builder.call(helpers.checker(request.path, false), [array, position], Void);
			bridge.writeValue(builder, array, position, value, request.type, request.path);
			builder.returnValue(builder.constVoid());
			result.push(new IrFunction(name, builder.arguments, Void, builder.blocks, ValueArrayElement));
		}
		finished = true;
		return result;
	}

	public function specialize(kind:compiler.ir.IrFunction.IrFunctionKind, name:String, fn:IrFunction, path:Array<String>):IrFunction {
		if (fn.arguments.length == 0 || !isValue(fn.arguments[0].type))
			throw 'Array place method "$name" has no value receiver';
		var receiver = fn.arguments[0], next = nextId(fn), array = new IrValue(next++, "$array-place", Array(element)),
			index = new IrValue(next++, "$array-index", I32), aliases:Map<Int, Array<String>> = [receiver.id => path.copy()],
			nulls:Map<Int, Bool> = [], fresh:Map<Int, Bool> = [];
		var changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case ConstNull(out): nulls.set(out.id, true);
				case NewObject(out, _) if (isValue(out.type)): fresh.set(out.id, true);
				case FieldGet(out, owner, field) if (aliases.exists(owner.id) && isValue(out.type) && !aliases.exists(out.id)):
					aliases.set(out.id, aliases.get(owner.id).concat([field])); changed = true;
				case SafeCast(out, value) if (aliases.exists(value.id) && isValue(out.type) && !aliases.exists(out.id)):
					aliases.set(out.id, aliases.get(value.id)); changed = true;
				default:
			}
		}
		// A freshly built value used only as a source for this place can remain a set of SSA field snapshots. Restrict
		// the current analysis to one block so writes and the copy are observed in their original order.
		var freshHomes:Map<Int, {block:Int, position:Int}> = [], virtualFresh:Map<Int, Bool> = [], copiedFresh:Map<Int, Bool> = [],
			freshLinks:Array<{child:Int, parent:Int}> = [];
		for (block in fn.blocks) for (position in 0...block.instructions.length) switch block.instructions[position].value {
			case NewObject(out, _) if (isValue(out.type)):
				freshHomes.set(out.id, {block: block.id, position: position}); virtualFresh.set(out.id, true);
			default:
		}
		// Optional wrappers of fresh values can also remain components when every use stores them in a fresh parent.
		var optionalHomes:Map<Int, {block:Int, position:Int, child:Int}> = [], optionalCandidates:Map<Int, Bool> = [],
			optionalUsed:Map<Int, Bool> = [];
		for (block in fn.blocks) for (position in 0...block.instructions.length) switch block.instructions[position].value {
			case ToDyn(out, value) if (freshHomes.exists(value.id) && isNullable(out.type) && isValue(out.type)):
				optionalHomes.set(out.id, {block: block.id, position: position, child: value.id}); optionalCandidates.set(out.id, true);
			default:
		}
		for (block in fn.blocks) {
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				for (input in IrOperands.inputs(instruction)) if (optionalHomes.exists(input.id)) {
					var home = optionalHomes.get(input.id), allowed = block.id == home.block && position > home.position;
					if (allowed) allowed = switch instruction {
						case FieldSet(owner, _, value) if (value.id == input.id && freshHomes.exists(owner.id)):
							optionalUsed.set(input.id, true); true;
						default: false;
					};
					if (!allowed) optionalCandidates.remove(input.id);
				}
				switch instruction {
					case Phi(_, inputs): for (input in inputs) if (optionalHomes.exists(input.value.id)) optionalCandidates.remove(input.value.id);
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (optionalHomes.exists(value.id)): optionalCandidates.remove(value.id);
				default:
			}
		}
		for (id in [for (id in optionalCandidates.keys()) id]) if (!optionalUsed.exists(id)) optionalCandidates.remove(id);
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case FieldSet(owner, _, value) if (optionalCandidates.exists(value.id)):
				var home = optionalHomes.get(value.id);
				if (home == null) throw 'Missing optional array value ${value.id}';
				freshLinks.push({child: home.child, parent: owner.id});
			default:
		}
		for (block in fn.blocks) {
			for (position in 0...block.instructions.length) {
				var instruction = block.instructions[position].value;
				for (input in IrOperands.inputs(instruction)) if (freshHomes.exists(input.id)) {
					var home = freshHomes.get(input.id), allowed = block.id == home.block && position > home.position;
					if (allowed) allowed = switch instruction {
						case FieldSet(owner, _, value) if (owner.id == input.id && value.id != input.id): true;
						case FieldSet(owner, _, value) if (value.id == input.id && aliases.exists(owner.id)):
							copiedFresh.set(input.id, true); true;
						case FieldSet(owner, _, value) if (value.id == input.id && owner.id != input.id && freshHomes.exists(owner.id)):
							freshLinks.push({child: input.id, parent: owner.id}); true;
						case ToDyn(out, value) if (value.id == input.id && optionalCandidates.exists(out.id)): true;
						default: false;
					};
					if (!allowed) virtualFresh.remove(input.id);
				}
				switch instruction {
					case Phi(_, inputs): for (input in inputs) if (freshHomes.exists(input.value.id)) virtualFresh.remove(input.value.id);
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (freshHomes.exists(value.id)): virtualFresh.remove(value.id);
				default:
			}
		}
		changed = true;
		while (changed) {
			changed = false;
			for (link in freshLinks) if (virtualFresh.exists(link.child) && !virtualFresh.exists(link.parent)) {
				virtualFresh.remove(link.child); changed = true;
			}
		}
		changed = true;
		while (changed) {
			changed = false;
			for (link in freshLinks) if (copiedFresh.exists(link.parent) && !copiedFresh.exists(link.child)) {
				copiedFresh.set(link.child, true); changed = true;
			}
		}
		for (id in [for (id in virtualFresh.keys()) id]) if (!copiedFresh.exists(id)) virtualFresh.remove(id);
		// Nullable scalar reads are snapshots. Carry their presence and payload through joins as separate SSA values,
		// including null and scalar constructors that feed a lane write or a join with a lane read.
		var needed:Map<Int, Bool> = [], optionalScalars:Map<Int, ArrayOptionalScalar> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case FieldGet(out, owner, _) if (aliases.exists(owner.id) && isNullableScalar(out.type)): needed.set(out.id, true);
			case FieldSet(owner, _, value) if (aliases.exists(owner.id) && isNullableScalar(value.type)): needed.set(value.id, true);
			case FieldSet(owner, _, value) if (virtualFresh.exists(owner.id) && isNullableScalar(value.type)): needed.set(value.id, true);
			default:
		}
		changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case Phi(out, inputs) if (isNullableScalar(out.type)):
					var related = needed.exists(out.id);
					for (input in inputs) if (needed.exists(input.value.id)) related = true;
					if (related) {
						if (!needed.exists(out.id)) { needed.set(out.id, true); changed = true; }
						for (input in inputs) if (!needed.exists(input.value.id)) { needed.set(input.value.id, true); changed = true; }
					}
				default:
			}
		}
		for (argument in fn.arguments) if (needed.exists(argument.id))
			throw 'Nullable scalar array place argument requires component specialization';
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output == null || !needed.exists(output.id)) continue;
			var payload:IrValue = switch located.value {
				case ToDyn(_, value) if (Type.enumEq(value.type, scalarInner(output.type))): value;
				case FieldGet(_, owner, _) if (aliases.exists(owner.id)): new IrValue(next++, "$array-optional-payload", scalarInner(output.type));
				case ConstNull(_), Phi(_, _): new IrValue(next++, "$array-optional-payload", scalarInner(output.type));
				default: throw 'Unsupported nullable scalar array place producer ${Std.string(located.value)}';
			};
			optionalScalars.set(output.id, {present: new IrValue(next++, "$array-optional-present", Bool), payload: payload});
		}
		var blocks:Array<IrBlock> = [], freshFields:Map<Int, Map<String, ArrayFreshField>> = [],
			optionalFresh:Map<Int, ArrayFreshField> = [];
		for (blockIndex in 0...fn.blocks.length) {
			var source = fn.blocks[blockIndex], target = new IrBlock(source.id), needsEntryCheck = blockIndex == 0;
			for (located in source.instructions) {
				var instruction = located.value, handled = false, omit = false;
				if (needsEntryCheck) switch instruction {
					case Phi(_, _):
					default:
						var check = new IrValue(next++, "$array-place-check", Void);
						target.instructions.push(new Located(Call(check, helpers.checker(path, true), [array, index]),
							compiler.ir.SourceProvenance.generated("array-place-receiver")));
						needsEntryCheck = false;
				}
				switch instruction {
					case NewObject(out, _) if (virtualFresh.exists(out.id)):
						freshFields.set(out.id, []); omit = true; handled = true;
					case ToDyn(out, value) if (optionalCandidates.exists(out.id) && virtualFresh.exists(value.id)):
						var nested = freshFields.get(value.id), present = new IrValue(next++, "$array-optional-struct-present", Bool);
						if (nested == null) throw 'Missing optional constructed array value';
						target.instructions.push(new Located(ConstBool(present, true), located.provenance));
						optionalFresh.set(out.id, {value: out, fields: nested.copy(), present: present}); omit = true; handled = true;
					case FieldSet(owner, field, value) if (virtualFresh.exists(owner.id)):
						var fields = freshFields.get(owner.id);
						if (fields == null) throw 'Missing constructed array value';
						var nested = virtualFresh.exists(value.id) ? freshFields.get(value.id) : null;
						if (virtualFresh.exists(value.id) && nested == null) throw 'Missing nested constructed array value';
						var optional = optionalFresh.get(value.id);
						if (optional != null) fields.set(field, optional);
						else if (isValue(value.type) && isNullable(value.type) && nulls.exists(value.id)) {
							var absent = new IrValue(next++, "$array-optional-struct-absent", Bool);
							target.instructions.push(new Located(ConstBool(absent, false), located.provenance));
							fields.set(field, {value: value, fields: [], present: absent});
						} else fields.set(field, {value: value, fields: nested == null ? null : nested.copy(), present: null});
						omit = true; handled = true;
					case ConstNull(out) if (optionalScalars.exists(out.id)):
						var value = optionalScalars.get(out.id);
						target.instructions.push(new Located(ConstBool(value.present, false), located.provenance));
						target.instructions.push(new Located(zero(value.payload), located.provenance));
						omit = true; handled = true;
					case ToDyn(out, _) if (optionalScalars.exists(out.id)):
						target.instructions.push(new Located(ConstBool(optionalScalars.get(out.id).present, true), located.provenance));
						omit = true; handled = true;
					case Phi(out, inputs) if (optionalScalars.exists(out.id)):
						var value = optionalScalars.get(out.id), presence:Array<IrPhiInput> = [], payload:Array<IrPhiInput> = [];
						for (input in inputs) {
							var components = optionalScalars.get(input.value.id);
							if (components == null) throw 'Missing nullable scalar phi input ${input.value.id}';
							presence.push({block: input.block, value: components.present});
							payload.push({block: input.block, value: components.payload});
						}
						target.instructions.push(new Located(Phi(value.present, presence), located.provenance));
						target.instructions.push(new Located(Phi(value.payload, payload), located.provenance));
						omit = true; handled = true;
					case FieldGet(out, owner, field) if (aliases.exists(owner.id)):
						var fieldPath = aliases.get(owner.id).concat([field]);
						var check = new IrValue(next++, "$array-place-check", Void);
						target.instructions.push(new Located(Call(check, helpers.checker(fieldPath, false), [array, index]), located.provenance));
						if (isValue(out.type)) omit = true;
						else if (optionalScalars.exists(out.id)) {
							var snapshot = optionalScalars.get(out.id);
							target.instructions.push(new Located(Call(snapshot.present, helpers.getter(helpers.slot(fieldPath, true)), [array, index]), located.provenance));
							target.instructions.push(new Located(Call(snapshot.payload, helpers.getter(helpers.slot(fieldPath, false, true)), [array, index]), located.provenance));
							omit = true;
						}
						else {
							instruction = Call(out, helpers.getter(helpers.slot(fieldPath)), [array, index]);
						}
						handled = true;
					case FieldSet(owner, field, value) if (aliases.exists(owner.id)):
						var fieldPath = aliases.get(owner.id).concat([field]), check = new IrValue(next++, "$array-place-check", Void),
							ignored = new IrValue(next++, "$array-place-write", Void);
						target.instructions.push(new Located(Call(check, helpers.checker(fieldPath, false), [array, index]), located.provenance));
						if (isValue(value.type) && aliases.exists(value.id)) {
							var sourcePath = aliases.get(value.id), sourceCheck = new IrValue(next++, "$array-place-source-check", Void),
								copies = helpers.copySlots(sourcePath, fieldPath), values:Array<IrValue> = [];
							target.instructions.push(new Located(Call(sourceCheck, helpers.checker(sourcePath, false), [array, index]), located.provenance));
							// Read all leaves first: the source and destination can share the same array element.
							for (copy in copies) {
								var leaf = new IrValue(next++, "$array-place-copy", copy.type);
								target.instructions.push(new Located(Call(leaf, helpers.getter(copy.source), [array, index]), located.provenance));
								values.push(leaf);
							}
							for (i in 0...copies.length) {
								var write = new IrValue(next++, "$array-place-copy-write", Void);
								target.instructions.push(new Located(Call(write, helpers.setter(copies[i].target), [array, index, values[i]]), located.provenance));
							}
							omit = true;
						} else if (isValue(value.type) && virtualFresh.exists(value.id)) {
							var fields = freshFields.get(value.id), slots = helpers.subtree(fieldPath), sourceValues:Array<IrValue> = [];
							if (fields == null) throw 'Missing constructed array value';
							for (entry in slots) {
								var relative = entry.slot.path.slice(fieldPath.length);
								if (relative.length == 0) throw 'Optional constructed array value requires component specialization';
								var field:Null<ArrayFreshField> = null, currentFields = fields;
								for (part in 0...relative.length) {
									field = currentFields.get(relative[part]);
									if (field == null) break;
									if (part + 1 < relative.length) {
										if (field.fields == null) throw 'Nested constructed array value requires component specialization';
										currentFields = field.fields;
									}
								}
								if (field == null) {
									// NewObject zero-initializes every field, including optional presence and reference slots.
									var initial = new IrValue(next++, "$array-place-default", entry.slot.type);
									target.instructions.push(new Located(defaultValue(initial), located.provenance));
									sourceValues.push(initial);
									continue;
								}
								var fieldValue = field.value;
								var scalar = optionalScalars.get(fieldValue.id), leaf:Null<IrValue> = entry.slot.isPresence
									? (field.present != null ? field.present : scalar == null ? null : scalar.present)
									: entry.slot.nullablePayload ? (scalar == null ? null : scalar.payload) : fieldValue;
								if (leaf == null)
									throw 'Constructed array field "${relative[0]}" requires component specialization';
								if (!IrVerifier.sameType(leaf.type, entry.slot.type))
									throw 'Constructed array field "${relative[0]}" requires component specialization';
								sourceValues.push(leaf);
							}
							for (i in 0...slots.length) {
								var write = new IrValue(next++, "$array-place-copy-write", Void);
								target.instructions.push(new Located(Call(write, helpers.setter(slots[i].index), [array, index, sourceValues[i]]), located.provenance));
							}
							omit = true;
						} else if (isValue(value.type) && !isNullable(value.type)) {
							var sourceValues:Array<IrValue> = [], slots = helpers.subtree(fieldPath);
							if (slots.length == 0 && !fresh.exists(value.id))
								throw 'Empty array value source requires a receiver check';
							for (entry in slots) {
								if (entry.slot.isPresence || entry.slot.nullablePayload)
									throw 'Optional source fields require component specialization';
								var current = value;
								for (part in entry.slot.path.slice(fieldPath.length)) {
									var type = fieldType(current.type, part), leaf = new IrValue(next++, "$array-place-source", type);
									target.instructions.push(new Located(FieldGet(leaf, current, part), located.provenance));
									current = leaf;
								}
								if (!IrVerifier.sameType(current.type, entry.slot.type)) throw 'Incompatible value source for array place';
								sourceValues.push(current);
							}
							for (i in 0...slots.length) {
								var write = new IrValue(next++, "$array-place-copy-write", Void);
								target.instructions.push(new Located(Call(write, helpers.setter(slots[i].index), [array, index, sourceValues[i]]), located.provenance));
							}
							omit = true;
						} else if (isValue(value.type) || aliases.exists(value.id))
							throw 'Composite array place write requires value specialization';
						else if (isNullableScalar(value.type)) {
							var snapshot = optionalScalars.get(value.id), inner = scalarInner(value.type);
							if (snapshot == null) throw 'Missing nullable scalar array place components';
							instruction = Call(ignored, helpers.optionalSetter(fieldPath, inner), [array, index, snapshot.present, snapshot.payload]);
						} else instruction = Call(ignored, helpers.setter(helpers.slot(fieldPath)), [array, index, value]);
						handled = true;
					case SafeCast(out, value) if (optionalScalars.exists(value.id)):
						var snapshot = optionalScalars.get(value.id);
						instruction = Call(out, helpers.requireScalar(out.type), [snapshot.present, snapshot.payload]); handled = true;
					case Equal(out, left, right) if ((optionalScalars.exists(left.id) && nulls.exists(right.id))
							|| (optionalScalars.exists(right.id) && nulls.exists(left.id))):
						var snapshot = optionalScalars.get(optionalScalars.exists(left.id) ? left.id : right.id),
							no = new IrValue(next++, "$array-optional-false", Bool);
						if (snapshot == null) throw "Missing nullable scalar comparison components";
						target.instructions.push(new Located(ConstBool(no, false), located.provenance));
						instruction = Equal(out, snapshot.present, no); handled = true;
					case SafeCast(out, value) if (aliases.exists(value.id) && aliases.exists(out.id)):
						var check = new IrValue(next++, "$array-place-check", Void);
						instruction = Call(check, helpers.checker(aliases.get(value.id), true), [array, index]);
						handled = true;
					case Equal(out, left, right) if ((aliases.exists(left.id) && nulls.exists(right.id))
							|| (aliases.exists(right.id) && nulls.exists(left.id))):
						var alias = aliases.exists(left.id) ? left : right;
						if (!isNullable(alias.type)) throw 'Non-null array place compared with null';
						var aliasPath = aliases.get(alias.id);
						if (aliasPath == null) throw "Missing optional array place";
						var present = new IrValue(next++, "$array-place-present", Bool), no = new IrValue(next++, "$array-place-false", Bool);
						target.instructions.push(new Located(Call(present, helpers.getter(helpers.slot(aliasPath, true)), [array, index]), located.provenance));
						target.instructions.push(new Located(ConstBool(no, false), located.provenance));
						instruction = Equal(out, present, no); handled = true;
					case MethodCall(out, owner, method, arguments, _) if (aliases.exists(owner.id)):
						for (argument in arguments) if (aliases.exists(argument.id) || optionalScalars.exists(argument.id))
							throw 'Array place argument requires value specialization';
						var nested = request(owner.type, method, aliases.get(owner.id));
						instruction = Call(out, nested, [array, index].concat(arguments)); handled = true;
					case Call(out, method, arguments) if (StringTools.startsWith(method, "$generic:") && arguments.length > 0
							&& aliases.exists(arguments[0].id)):
						for (argument in arguments.slice(1)) if (aliases.exists(argument.id) || optionalScalars.exists(argument.id))
							throw 'Array place argument requires value specialization';
						var nested = request(arguments[0].type, method, aliases.get(arguments[0].id));
						instruction = Call(out, nested, [array, index].concat(arguments.slice(1))); handled = true;
					default:
				}
				if (!handled) {
					for (input in IrOperands.inputs(instruction)) {
						if (aliases.exists(input.id)) throw 'Array place receiver escapes through ${Std.string(instruction)}';
						if (optionalScalars.exists(input.id)) throw 'Nullable scalar snapshot escapes through ${Std.string(instruction)}';
						if (virtualFresh.exists(input.id)) throw 'Constructed array value escapes through ${Std.string(instruction)}';
					}
					switch instruction {
						case Phi(_, inputs):
							for (input in inputs) if (aliases.exists(input.value.id) || optionalScalars.exists(input.value.id))
								throw 'Array place value requires component phi specialization';
						default:
					}
				}
				if (!omit) target.instructions.push(new Located(instruction, located.provenance));
			}
			if (needsEntryCheck) {
				var check = new IrValue(next++, "$array-place-check", Void);
				target.instructions.push(new Located(Call(check, helpers.checker(path, true), [array, index]),
					compiler.ir.SourceProvenance.generated("array-place-receiver")));
			}
			if (source.terminator != null) switch source.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _)
						if (aliases.exists(value.id) || optionalScalars.exists(value.id) || virtualFresh.exists(value.id)):
					throw 'Array place receiver escapes through a terminator';
				default:
			}
			target.terminator = source.terminator;
			blocks.push(target);
		}
		var debug = [for (binding in fn.debugBindings) if (!aliases.exists(binding.value.id) && !optionalScalars.exists(binding.value.id)
			&& !virtualFresh.exists(binding.value.id) && !optionalFresh.exists(binding.value.id)) binding];
		return new IrFunction(name, [array, index].concat(fn.arguments.slice(1)), fn.result, blocks, kind, debug, fn.inlineHint, fn.retention);
	}

	function request(receiverType:IrType, method:String, path:Array<String>):String {
		var encoded = haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(haxe.Json.stringify([method, path]))),
			name = PREFIX + haxe.crypto.Base64.encode(IrTypeCodec.encode(element)) + ":" + encoded;
		if (!requested.exists(name)) {
			requested.set(name, true);
			requests.push({name: name, receiverType: receiverType, method: method, path: path.copy()});
		}
		return name;
	}

	function resolveMethod(receiverType:IrType, method:String, originals:Map<String, IrFunction>):String {
		if (originals.exists(method)) return method;
		var name = switch receiverType {
			case Obj(value), Nullable(Obj(value)): value;
			default: throw 'Invalid array place method receiver $receiverType';
		};
		while (name != null) {
			var object = objects.get(name);
			if (object == null) break;
			for (candidate in object.methods) if (candidate.name == method) return candidate.functionName;
			name = object.base;
		}
		throw 'Unknown array place method "$method" on $receiverType';
	}

	function isValue(type:IrType):Bool return switch type {
		case Obj(name), Nullable(Obj(name)):
			var object = objects.get(name);
			object != null && object.isValue;
		default: false;
	};

	function fieldType(type:IrType, field:String):IrType {
		var name = switch type {
			case Obj(value): value;
			default: throw 'Cannot project "$field" from $type';
		};
		var object = objects.get(name);
		if (object == null) throw 'Missing value source "$name"';
		for (candidate in object.fields) if (candidate.name == field) return candidate.type;
		throw 'Missing value source field "$name.$field"';
	}

	static function isNullable(type:IrType):Bool return switch type { case Nullable(_): true; default: false; };
	static function isNullableScalar(type:IrType):Bool return switch type {
		case Nullable(I32), Nullable(I64), Nullable(F32), Nullable(F64), Nullable(Bool): true;
		default: false;
	};

	static function scalarInner(type:IrType):IrType return switch type {
		case Nullable(inner) if (isNullableScalar(type)): inner;
		default: throw 'Not a nullable scalar: $type';
	};

	static function zero(value:IrValue):IrInstruction return switch value.type {
		case I32, I64: ConstInt(value, 0);
		case F32, F64: ConstFloat(value, 0);
		case Bool: ConstBool(value, false);
		default: throw 'Invalid optional scalar payload ${value.type}';
	};

	static function defaultValue(value:IrValue):IrInstruction return switch value.type {
		case I32, I64, F32, F64, Bool: zero(value);
		default: ConstNull(value);
	};

	static function nextId(fn:IrFunction):Int {
		var next = 0;
		for (arg in fn.arguments) if (arg.id >= next) next = arg.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null && output.id >= next) next = output.id + 1;
			for (input in IrOperands.inputs(located.value)) if (input.id >= next) next = input.id + 1;
		}
		return next;
	}
}
