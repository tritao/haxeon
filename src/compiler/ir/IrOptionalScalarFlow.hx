package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.SourceProvenance.Located;

private typedef OptionalAlias = {final root:Int; final path:Array<String>; final typeName:String;}
private typedef OptionalClosure = {final name:String; final receiver:Null<IrValue>;}

/** Scalar components for optional values that do not need a boxed representation. */
class IrOptionalScalarFlow {
	public static inline final PREFIX = "$optional-scalar:";
	public static inline final WRAPPER = "$optional-components:";
	final objects:Map<String, IrObject>;
	final layouts:IrInlineValueLayout;
	final wrappers:Map<String, IrObject> = [];
	var candidates:Map<String, IrFunction> = [];
	final functions:Map<String, IrFunction> = [];

	public function new(declarations:Array<IrObject>) {
		objects = [for (object in declarations) object.name => object];
		layouts = new IrInlineValueLayout(IrObjectTable.of(objects));
	}

	public function rewrite(declarations:Array<IrObject>, originals:Array<IrFunction>):Array<IrFunction> {
		for (fn in originals) functions.set(fn.name, fn);
		for (fn in originals) {
			var signature = optional(fn.result) != null;
			for (arg in fn.arguments) if (optional(arg.type) != null) signature = true;
			if (signature && !StringTools.startsWith(fn.name, PREFIX)) candidates.set(fn.name, fn);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (fn in originals) if (candidates.exists(fn.name) && !eligible(fn)) { candidates.remove(fn.name); changed = true; }
		}
		var rewritten:Array<IrFunction> = [];
		for (fn in originals) {
			var signature = optional(fn.result) != null;
			for (arg in fn.arguments) if (optional(arg.type) != null) signature = true;
			rewritten.push(!signature && hasOptional(fn) && eligible(fn) ? transform(fn, false) : fn);
		}
		for (fn in originals) if (candidates.exists(fn.name)) rewritten.push(transform(fn, true));
		var names = [for (name in wrappers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) declarations.push(wrappers.get(name));
		return rewritten;
	}

	function optional(type:IrType):Null<String> return switch type {
		case Nullable(Obj(name)) if (objects.exists(name) && objects.get(name).isValue): name;
		default: null;
	};
	function hasOptional(fn:IrFunction):Bool {
		for (arg in fn.arguments) if (optional(arg.type) != null) return true;
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null && optional(out.type) != null) return true;
		}
		return optional(fn.result) != null;
	}
	function slots(name:String):Array<IrInlineValueSlot> return layouts.slots(Nullable(Obj(name)));
	public static function wrapperName(name:String):String return WRAPPER + name;
	function wrapper(name:String):IrObject {
		if (!wrappers.exists(name)) {
			var fields:Array<IrObjectField> = [];
			var shape = slots(name);
			for (i in 0...shape.length) fields.push({name: "$slot" + i, type: shape[i].type});
			wrappers.set(name, {name: wrapperName(name), isValue: true, base: null, interfaces: [], fields: fields, methods: []});
		}
		return wrappers.get(name);
	}
	function closureBindings(fn:IrFunction):Map<Int, OptionalClosure> {
		var result:Map<Int, OptionalClosure> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case StaticClosure(out, name): result.set(out.id, {name: name, receiver: null});
			case InstanceClosure(out, name, receiver): result.set(out.id, {name: name, receiver: receiver});
			default:
		}
		return result;
	}
	function exactTypes(fn:IrFunction):Map<Int, String> {
		var result:Map<Int, String> = [], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case NewObject(out, name) if (!result.exists(out.id)): result.set(out.id, name); changed = true;
				case Upcast(out, value) if (!result.exists(out.id) && result.exists(value.id)): result.set(out.id, result.get(value.id)); changed = true;
				case Phi(out, inputs) if (!result.exists(out.id) && inputs.length > 0):
					var name:Null<String> = null, same = true;
					for (input in inputs) {
						var type = result.get(input.value.id);
						if (type == null || (name != null && name != type)) same = false; else name = type;
					}
					if (same && name != null) { result.set(out.id, name); changed = true; }
				default:
			}
		}
		return result;
	}
	function method(typeName:Null<String>, name:String):Null<String> {
		while (typeName != null) {
			var object = objects.get(typeName);
			if (object == null) return null;
			for (entry in object.methods) if (entry.name == name) return entry.functionName;
			typeName = object.base;
		}
		return null;
	}
	function hasCandidateMethod(exact:Map<Int, String>, receiver:IrValue, name:String):Bool {
		var target = method(exact.get(receiver.id), name);
		return target != null && candidates.exists(target);
	}
	function aliases(fn:IrFunction):Map<Int, OptionalAlias> {
		var result:Map<Int, OptionalAlias> = [], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case SafeCast(out, source) if (optional(source.type) != null && Type.enumEq(out.type, Obj(optional(source.type)))):
					if (!result.exists(out.id)) { result.set(out.id, {root: source.id, path: [], typeName: optional(source.type)}); changed = true; }
				case FieldGet(out, owner, field) if (result.exists(owner.id)):
					switch out.type {
						case Obj(name) if (objects.exists(name) && objects.get(name).isValue && !result.exists(out.id)):
							var parent:OptionalAlias = cast result.get(owner.id);
							result.set(out.id, {root: parent.root, path: parent.path.concat([field]), typeName: parent.typeName}); changed = true;
						default:
					}
				default:
			}
		}
		return result;
	}
	function physicalField(type:IrType, physicalName:String):Null<{path:Array<String>, presence:Bool}> {
		var name = switch type { case Obj(value): value; default: return null; };
		while (name != null) {
			var object = objects.get(name);
			if (object == null) return null;
			for (field in object.fields) {
				var child = optional(field.type);
				if (child != null) for (slot in slots(child))
					if (IrInlineValueLayout.slotName(field.name, slot) == physicalName)
						return {path: [field.name].concat(slot.path), presence: slot.isPresence};
			}
			name = object.base;
		}
		return null;
	}
	function declaredField(type:IrType, field:String):Null<IrObjectField> {
		var name = switch type { case Obj(value): value; default: return null; };
		while (name != null) {
			var object = objects.get(name);
			if (object == null) return null;
			for (entry in object.fields) if (entry.name == field) return entry;
			name = object.base;
		}
		return null;
	}
	function inlineOptionalField(owner:IrValue, field:String, type:IrType):Bool {
		var declared = declaredField(owner.type, field);
		return declared != null && optional(declared.type) != null && Type.enumEq(declared.type, type);
	}

	function hasAlias(arguments:Array<IrValue>, aliases:Map<Int, OptionalAlias>):Bool {
		for (argument in arguments) if (aliases.exists(argument.id)) return true;
		return false;
	}
	function canPassAliases(name:String, arguments:Array<IrValue>, aliases:Map<Int, OptionalAlias>):Bool {
		if (!hasAlias(arguments, aliases)) return true;
		if (StringTools.startsWith(name, "$") && !StringTools.startsWith(name, "$generic:")
				&& !StringTools.startsWith(name, "$lambda:") && !StringTools.startsWith(name, "$value$equality:")) return false;
		var called = functions.get(name);
		if (called == null || called.arguments.length != arguments.length) return false;
		for (index in 0...arguments.length) if (aliases.exists(arguments[index].id)) {
			var formal = called.arguments[index];
			if (formal.name == "this" || !Type.enumEq(formal.type, arguments[index].type)) return false;
		}
		return true;
	}
	function eligible(fn:IrFunction):Bool {
		var nulls:Map<Int, Bool> = [], values:Map<Int, Bool> = [], alias = aliases(fn), bindings = closureBindings(fn), exact = exactTypes(fn);
		for (arg in fn.arguments) if (optional(arg.type) != null) values.set(arg.id, true);
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null && optional(out.type) != null) values.set(out.id, true);
			switch located.value { case ConstNull(out) if (optional(out.type) != null): nulls.set(out.id, true); default: }
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var op = located.value, out = IrOperands.output(op), involved = out != null && values.exists(out.id);
				for (input in IrOperands.inputs(op)) if (values.exists(input.id) || alias.exists(input.id)) involved = true;
				switch op {
					case Phi(_, inputs): for (input in inputs) if (values.exists(input.value.id) || alias.exists(input.value.id)) involved = true;
					default:
				}
				if (!involved) continue;
				switch op {
					case ConstNull(out) if (values.exists(out.id)):
					case Phi(out, inputs) if (values.exists(out.id)):
						for (input in inputs) if (!values.exists(input.value.id) || !Type.enumEq(input.value.type, out.type)) return false;
					case Phi(_, inputs):
						for (input in inputs) if (values.exists(input.value.id) || alias.exists(input.value.id)) return false;
					case FieldGet(out, owner, _) if (values.exists(out.id) && !alias.exists(owner.id)):
					case FieldGet(_, owner, field) if (alias.exists(owner.id)):
						if (physicalField(owner.type, field) == null && declaredField(owner.type, field) == null) return false;
						var declaration = declaredField(owner.type, field);
						if (declaration != null) switch declaration.type {
							case Nullable(Obj(_)) if (optional(declaration.type) == null): return false;
							default:
						}
					case FieldSet(owner, field, value) if (alias.exists(owner.id) && !alias.exists(value.id)):
						var physical = physicalField(owner.type, field), declared = declaredField(owner.type, field);
						if (physical == null && declared == null) return false;
						if (physical == null && declared != null) switch declared.type {
							case Obj(name) if (objects.exists(name) && objects.get(name).isValue): return false;
							case Nullable(Obj(_)) if (optional(declared.type) == null): return false;
							default:
						}
					case FieldSet(owner, _, value) if (!alias.exists(owner.id) && values.exists(value.id)):
					case ToDyn(out, source) if (values.exists(out.id) && Type.enumEq(source.type, Obj(optional(out.type)))):
					case SafeCast(out, source) if (alias.exists(out.id) && values.exists(source.id)):
					case Equal(_, left, right) if ((values.exists(left.id) && nulls.exists(right.id)) || (values.exists(right.id) && nulls.exists(left.id))):
					case Call(out, name, args) if (IrOptionalValueFlow.isCopyName(name) && values.exists(out.id) && args.length == 1 && values.exists(args[0].id)):
					case Call(_, name, args) if (candidates.exists(name) || hasAlias(args, alias)):
						if (!canPassAliases(name, args, alias)) return false;
					case CallClosure(_, closure, args) if (bindings.exists(closure.id) && (candidates.exists(bindings.get(closure.id).name) || hasAlias(args, alias))):
						var binding:OptionalClosure = cast bindings.get(closure.id), actual = binding.receiver == null ? args : [binding.receiver].concat(args);
						if (!canPassAliases(binding.name, actual, alias)) return false;
					case MethodCall(_, receiver, name, args) if (!alias.exists(receiver.id) && (hasCandidateMethod(exact, receiver, name) || hasAlias(args, alias))):
						var target = method(exact.get(receiver.id), name);
						if (target == null || !canPassAliases(target, [receiver].concat(args), alias)) return false;
					default:
						// Unsupported reference-representation operations remain explicit box/unbox boundaries.
						for (input in IrOperands.inputs(op)) if (alias.exists(input.id)) return false;
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value) if (values.exists(value.id)):
					if (optional(fn.result) == null) return false;
				case Throw(value), Rethrow(value) if (values.exists(value.id)):
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (alias.exists(value.id) || values.exists(value.id)): return false;
				default:
			}
		}
		return true;
	}

	function transform(fn:IrFunction, clone:Bool):IrFunction {
		var next = 0;
		for (arg in fn.arguments) if (arg.id >= next) next = arg.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null && out.id >= next) next = out.id + 1;
		}
		var types:Map<Int, String> = [], components:Map<Int, Array<IrValue>> = [], nulls:Map<Int, Bool> = [];
		function component(id:Int):Array<IrValue> {
			var result = components.get(id);
			if (result == null) throw 'Missing optional scalar components for $id';
			return result;
		}
		function allocate(value:IrValue):Void {
			var name = optional(value.type);
			if (name == null || components.exists(value.id)) return;
			types.set(value.id, name);
			components.set(value.id, [for (slot in slots(name)) new IrValue(next++, "$optional-slot", slot.type)]);
		}
		for (arg in fn.arguments) allocate(arg);
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null) allocate(out);
			switch located.value { case ConstNull(out) if (optional(out.type) != null): nulls.set(out.id, true); default: }
		}
		var alias = aliases(fn), bindings = closureBindings(fn), exact = exactTypes(fn), substitutions:Map<Int, IrValue> = [], holders:Map<Int, IrValue> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case FieldSet(owner, _, _) if (alias.exists(owner.id)):
				var receiver:OptionalAlias = cast alias.get(owner.id), root = receiver.root;
				if (!holders.exists(root)) holders.set(root, new IrValue(next++, "$optional-place", Obj(wrapper(types.get(root)).name)));
			default:
		}
		var
			origin = SourceProvenance.generated("optional-scalar-flow"), args:Array<IrValue> = [], prefix:Array<Located<IrInstruction>> = [];
		for (arg in fn.arguments) {
			var name = optional(arg.type);
			if (name == null) args.push(arg);
			else {
				var aggregate = new IrValue(next++, arg.name, Obj(wrapper(name).name));
				args.push(aggregate);
				var parts = component(arg.id);
				for (i in 0...parts.length) prefix.push(new Located(FieldGet(parts[i], aggregate, "$slot" + i), origin));
				if (holders.exists(arg.id)) {
					var holder = holders.get(arg.id);
					prefix.push(new Located(NewObject(holder, wrapper(name).name), origin));
					for (i in 0...parts.length) prefix.push(new Located(FieldSet(holder, "$slot" + i, parts[i]), origin));
				}
			}
		}
		function add(block:IrBlock, instruction:IrInstruction, from:Located<IrInstruction>):Void
			block.instructions.push(new Located(instruction, from.provenance));
		function install(block:IrBlock, id:Int, from:Located<IrInstruction>):Void {
			if (!holders.exists(id)) return;
			var holder = holders.get(id), parts = component(id);
			add(block, NewObject(holder, wrapper(types.get(id)).name), from);
			for (i in 0...parts.length) add(block, FieldSet(holder, "$slot" + i, parts[i]), from);
		}
		function partsAt(block:IrBlock, id:Int, from:Located<IrInstruction>):Array<IrValue> {
			if (!holders.exists(id)) return component(id);
			var holder = holders.get(id), shape = slots(types.get(id)), parts:Array<IrValue> = [];
			for (i in 0...shape.length) {
				var value = new IrValue(next++, "$optional-current", shape[i].type);
				add(block, FieldGet(value, holder, "$slot" + i), from); parts.push(value);
			}
			return parts;
		}
		function zero(out:IrValue):IrInstruction return switch out.type {
			case Bool: ConstBool(out, false);
			case I32, I64: ConstInt(out, 0);
			case F32, F64: ConstFloat(out, 0.0);
			default: ConstNull(out);
		};
		function slotIndex(rootName:String, path:Array<String>, presence:Bool):Int {
			var shape = slots(rootName);
			for (i in 0...shape.length) if (shape[i].isPresence == presence && IrOptionalValueFlow.samePath(shape[i].path, path)) return i;
			throw 'Missing optional scalar slot ${path.join(".")}';
		}
		function storeSlot(block:IrBlock, holder:IrValue, name:String, index:Int, value:IrValue, from:Located<IrInstruction>):Void {
			var slot = slots(name)[index], native = slot.nativeLayout, bits = switch value.type { case I32: 32; case I64: 64; default: 0; };
			if (native != null && bits > 0 && native.size > 0 && native.size * 8 < bits) {
				var shift = new IrValue(next++, "$optional-shift", I32), shifted = new IrValue(next++, "$optional-truncate", value.type),
					result = new IrValue(next++, "$optional-extend", value.type);
				add(block, ConstInt(shift, bits - native.size * 8), from);
				add(block, ShiftLeft(shifted, value, shift), from);
				add(block, native.signed ? ShiftRight(result, shifted, shift) : UnsignedShiftRight(result, shifted, shift), from);
				value = result;
			} else if (value.type == F32) {
				var wide = new IrValue(next++, "$optional-f64", F64), rounded = new IrValue(next++, "$optional-f32", F32);
				add(block, FloatToFloat(wide, value), from);
				add(block, FloatToFloat(rounded, wide), from);
				value = rounded;
			}
			add(block, FieldSet(holder, "$slot" + index, value), from);
		}
		function field(type:IrType, name:String):IrObjectField {
			var owner = switch type { case Obj(value): value; default: throw "Invalid value field owner"; };
			while (owner != null) {
				var object = objects.get(owner);
				if (object == null) break;
				for (candidate in object.fields) if (candidate.name == name) return candidate;
				owner = object.base;
			}
			throw 'Missing value field $name';
		}
		function aliasValue(block:IrBlock, source:IrValue, from:Located<IrInstruction>):IrValue {
			var a:OptionalAlias = cast alias.get(source.id), root = partsAt(block, a.root, from);
			function build(name:String, path:Array<String>):IrValue {
				var result = new IrValue(next++, "$optional-alias-copy", Obj(name)), object = objects.get(name);
				if (object == null) throw 'Missing optional alias value "$name"';
				add(block, NewObject(result, name), from);
				for (entry in object.fields) {
					var pathField = path.concat([entry.name]), child = optional(entry.type);
					if (child != null) {
						for (slot in slots(child)) {
							var index = slotIndex(a.typeName, pathField.concat(slot.path), slot.isPresence);
							add(block, FieldSet(result, IrInlineValueLayout.slotName(entry.name, slot), root[index]), from);
						}
					} else switch entry.type {
						case Obj(childName) if (objects.exists(childName) && objects.get(childName).isValue):
							add(block, FieldSet(result, entry.name, build(childName, pathField)), from);
						default:
							add(block, FieldSet(result, entry.name, root[slotIndex(a.typeName, pathField, false)]), from);
					}
				}
				return result;
			}
			return switch source.type { case Obj(name): build(name, a.path); default: throw "Invalid optional alias value"; };
		}
		function readValue(block:IrBlock, source:IrValue, name:String, output:Array<IrValue>, from:Located<IrInstruction>):Void {
			add(block, ConstBool(output[0], true), from);
			var shape = slots(name);
			for (index in 1...shape.length) {
				var slot = shape[index], current = source;
				for (partIndex in 0...slot.path.length) {
					var part = slot.path[partIndex], declaration = field(current.type, part), last = partIndex == slot.path.length - 1;
					if (optional(declaration.type) != null) {
						var sub:IrInlineValueSlot = {path: slot.path.slice(partIndex + 1), type: slot.type, isPresence: slot.isPresence, nativeLayout: slot.nativeLayout};
						add(block, FieldGet(output[index], current, IrInlineValueLayout.slotName(part, sub)), from);
						break;
					}
					if (last) add(block, FieldGet(output[index], current, part), from);
					else {
						var child = new IrValue(next++, "$optional-child", declaration.type);
						add(block, FieldGet(child, current, part), from); current = child;
					}
				}
			}
		}
		function aggregate(block:IrBlock, name:String, parts:Array<IrValue>, from:Located<IrInstruction>):IrValue {
			var target = new IrValue(next++, "$optional-components", Obj(wrapper(name).name));
			add(block, NewObject(target, wrapper(name).name), from);
			for (i in 0...parts.length) add(block, FieldSet(target, "$slot" + i, parts[i]), from);
			return target;
		}
		function box(block:IrBlock, value:IrValue, from:Located<IrInstruction>):IrValue {
			var name = types.get(value.id), packed = aggregate(block, name, partsAt(block, value.id, from), from),
				result = new IrValue(next++, "$optional-boxed", value.type);
			add(block, Call(result, IrOptionalValueFlow.boxName(name), [packed]), from);
			return result;
		}
		function unbox(block:IrBlock, value:IrValue, output:IrValue, from:Located<IrInstruction>):Void {
			var name = types.get(output.id), packed = new IrValue(next++, "$optional-unboxed", Obj(wrapper(name).name));
			add(block, Call(packed, IrOptionalValueFlow.unboxName(name), [value]), from);
			var parts = component(output.id);
			for (i in 0...parts.length) add(block, FieldGet(parts[i], packed, "$slot" + i), from);
		}
		function emitCall(block:IrBlock, out:IrValue, name:String, arguments:Array<IrValue>, from:Located<IrInstruction>):Void {
			var expanded:Array<IrValue> = [];
			for (arg in arguments) expanded.push(components.exists(arg.id) ? aggregate(block, types.get(arg.id), partsAt(block, arg.id, from), from) : arg);
			if (components.exists(out.id)) {
				var valueName = types.get(out.id), result = new IrValue(next++, "$optional-result", Obj(wrapper(valueName).name));
				add(block, Call(result, PREFIX + name, expanded), from);
				var parts = component(out.id);
				for (i in 0...parts.length) add(block, FieldGet(parts[i], result, "$slot" + i), from);
			} else add(block, Call(out, PREFIX + name, expanded), from);
		}
		var blocks:Array<IrBlock> = [], pendingReads:Map<Int, Array<Located<IrInstruction>>> = [], copies:Map<Int, IrBlock> = [];
		for (block in fn.blocks) { var target = new IrBlock(block.id); blocks.push(target); copies.set(block.id, target); }
		for (blockIndex in 0...fn.blocks.length) {
			var block = fn.blocks[blockIndex], target:IrBlock = cast copies.get(block.id), phiInstall:Array<{id:Int, from:Located<IrInstruction>}> = [], installed = false;
			if (blockIndex == 0) for (instruction in prefix) target.instructions.push(instruction);
			for (located in block.instructions) {
				var op = located.value;
				switch op {
					case Phi(_, _):
					default:
						if (!installed) { for (entry in phiInstall) install(target, entry.id, entry.from); installed = true; }
				}
				switch op {
					case ConstNull(out) if (components.exists(out.id)):
						for (part in component(out.id)) add(target, zero(part), located);
					case Phi(out, incoming) if (components.exists(out.id)):
						var parts = component(out.id);
						var sources:Array<Array<IrValue>> = [];
						for (input in incoming) {
							if (!holders.exists(input.value.id)) sources.push(component(input.value.id));
							else {
								var pending = new IrBlock(input.block), values = partsAt(pending, input.value.id, located), list = pendingReads.get(input.block);
								if (list == null) { list = []; pendingReads.set(input.block, list); }
								for (item in pending.instructions) list.push(item);
								sources.push(values);
							}
						}
						for (i in 0...parts.length) add(target, Phi(parts[i], [for (j in 0...incoming.length) {block: incoming[j].block, value: sources[j][i]}]), located);
						if (holders.exists(out.id)) phiInstall.push({id: out.id, from: located});
					case FieldGet(out, owner, name) if (alias.exists(owner.id)):
						var a:OptionalAlias = cast alias.get(owner.id), physical = physicalField(owner.type, name), path = a.path.concat([name]),
							root = partsAt(target, a.root, located);
						if (physical != null) substitutions.set(out.id, root[slotIndex(a.typeName, a.path.concat(physical.path), physical.presence)]);
						else if (components.exists(out.id)) {
							var shape = slots(types.get(out.id)), parts = component(out.id);
							for (i in 0...parts.length) substitutions.set(parts[i].id, root[slotIndex(a.typeName, path.concat(shape[i].path), shape[i].isPresence)]);
						} else if (!alias.exists(out.id)) substitutions.set(out.id, root[slotIndex(a.typeName, path, false)]);
					case FieldGet(out, owner, name) if (components.exists(out.id) && inlineOptionalField(owner, name, out.type)):
						var shape = slots(types.get(out.id)), parts = component(out.id);
						for (i in 0...parts.length) add(target, FieldGet(parts[i], owner, IrInlineValueLayout.slotName(name, shape[i])), located);
					case FieldSet(owner, name, value) if (alias.exists(owner.id)):
						var a:OptionalAlias = cast alias.get(owner.id), physical = physicalField(owner.type, name), path = a.path.concat([name]), holder = holders.get(a.root);
						if (components.exists(value.id)) {
							var shape = slots(types.get(value.id)), parts = partsAt(target, value.id, located);
							for (i in 0...parts.length)
								storeSlot(target, holder, a.typeName, slotIndex(a.typeName, path.concat(shape[i].path), shape[i].isPresence), parts[i], located);
						} else if (physical != null) storeSlot(target, holder, a.typeName, slotIndex(a.typeName, a.path.concat(physical.path), physical.presence), value, located);
						else storeSlot(target, holder, a.typeName, slotIndex(a.typeName, path, false), value, located);
					case FieldSet(owner, name, value) if (components.exists(value.id) && inlineOptionalField(owner, name, value.type)):
						var shape = slots(types.get(value.id)), parts = partsAt(target, value.id, located);
						for (i in 0...parts.length) add(target, FieldSet(owner, IrInlineValueLayout.slotName(name, shape[i]), parts[i]), located);
					case ToDyn(out, source) if (components.exists(out.id)):
						var parts = component(out.id), name = types.get(out.id);
						if (alias.exists(source.id)) {
							add(target, ConstBool(parts[0], true), located);
							var shape = slots(name), a:OptionalAlias = cast alias.get(source.id), root = partsAt(target, a.root, located);
							for (i in 1...parts.length) substitutions.set(parts[i].id, root[slotIndex(a.typeName, a.path.concat(shape[i].path), shape[i].isPresence)]);
						} else readValue(target, source, name, parts, located);
					case SafeCast(out, _) if (alias.exists(out.id)):
					case Equal(out, left, right) if ((components.exists(left.id) || components.exists(right.id)) && (nulls.exists(left.id) || nulls.exists(right.id))):
						var value = nulls.exists(left.id) ? right : left, no = new IrValue(next++, "$optional-absent", Bool);
						add(target, ConstBool(no, false), located);
						add(target, Equal(out, partsAt(target, value.id, located)[0], no), located);
					case Call(out, name, arguments) if (IrOptionalValueFlow.isCopyName(name) && components.exists(out.id)
							&& arguments.length == 1 && components.exists(arguments[0].id)):
						var from = partsAt(target, arguments[0].id, located), to = component(out.id);
						for (i in 0...to.length) substitutions.set(to[i].id, from[i]);
					case CallClosure(out, closure, arguments) if (bindings.exists(closure.id) && candidates.exists(bindings.get(closure.id).name)):
						var binding:OptionalClosure = cast bindings.get(closure.id), args = binding.receiver == null ? arguments : [binding.receiver].concat(arguments);
						var actual = [for (argument in args) alias.exists(argument.id) ? aliasValue(target, argument, located) : argument];
						emitCall(target, out, binding.name, actual, located);
					case Call(out, name, arguments) if (candidates.exists(name)):
						var actual = [for (argument in arguments) alias.exists(argument.id) ? aliasValue(target, argument, located) : argument];
						emitCall(target, out, name, actual, located);
					case MethodCall(out, receiver, name, arguments) if (!alias.exists(receiver.id) && hasCandidateMethod(exact, receiver, name)):
						var actual = [for (argument in [receiver].concat(arguments)) alias.exists(argument.id) ? aliasValue(target, argument, located) : argument];
						emitCall(target, out, method(exact.get(receiver.id), name), actual, located);
					case Call(out, name, arguments) if (hasAlias(arguments, alias)):
						var actual = [for (argument in arguments) alias.exists(argument.id) ? aliasValue(target, argument, located) : components.exists(argument.id) ? box(target, argument, located) : argument];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, Call(output, name, actual), located); unbox(target, output, out, located);
						} else add(target, Call(out, name, actual), located);
					case CallClosure(out, closure, arguments) if (bindings.exists(closure.id) && bindings.get(closure.id).receiver == null
							&& functions.exists(bindings.get(closure.id).name) && !hasAlias(arguments, alias)):
						var binding:OptionalClosure = cast bindings.get(closure.id);
						var boxed = [for (argument in arguments) components.exists(argument.id) ? box(target, argument, located) : argument];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, Call(output, binding.name, boxed), located); unbox(target, output, out, located);
						} else add(target, Call(out, binding.name, boxed), located);
					case CallClosure(out, closure, arguments) if (bindings.exists(closure.id) && hasAlias(arguments, alias)):
						var binding:OptionalClosure = cast bindings.get(closure.id), args = binding.receiver == null ? arguments : [binding.receiver].concat(arguments);
						var actual = [for (argument in args) alias.exists(argument.id) ? aliasValue(target, argument, located) : components.exists(argument.id) ? box(target, argument, located) : argument];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, Call(output, binding.name, actual), located); unbox(target, output, out, located);
						} else add(target, Call(out, binding.name, actual), located);
					case MethodCall(out, receiver, name, arguments) if (!alias.exists(receiver.id) && hasAlias(arguments, alias)):
						var actual = [for (argument in arguments) alias.exists(argument.id) ? aliasValue(target, argument, located) : components.exists(argument.id) ? box(target, argument, located) : argument];
						if (components.exists(out.id)) {
							var output = new IrValue(next++, "$optional-boundary-result", out.type);
							add(target, MethodCall(output, receiver, name, actual), located); unbox(target, output, out, located);
						} else add(target, MethodCall(out, receiver, name, actual), located);
					default:
						var remapped:Map<Int, IrValue> = [], out = IrOperands.output(op), changed = false;
						for (input in IrOperands.inputs(op)) if (components.exists(input.id) && !remapped.exists(input.id)) {
							remapped.set(input.id, box(target, input, located)); changed = true;
						}
						var boxedOutput:Null<IrValue> = null;
						if (out != null && components.exists(out.id)) {
							boxedOutput = new IrValue(next++, "$optional-boundary-result", out.type);
							remapped.set(out.id, boxedOutput); changed = true;
						}
						if (!changed) target.instructions.push(located);
						else {
							var instruction = IrInliner.remap(op, value -> remapped.exists(value.id) ? remapped.get(value.id) : value, id -> id);
							target.instructions.push(new Located(instruction, located.provenance));
							if (boxedOutput != null) unbox(target, boxedOutput, out, located);
						}
				}
				switch op {
					case Phi(_, _):
					default:
						var out = IrOperands.output(op);
						if (out != null && components.exists(out.id)) install(target, out.id, located);
				}
			}
			if (!installed) for (entry in phiInstall) install(target, entry.id, entry.from);
			var terminator = block.terminator;
			target.terminator = terminator;
			if (terminator != null) switch terminator.value {
				case Return(value) if (components.exists(value.id)):
					var here:Located<IrInstruction> = new Located(ConstVoid(new IrValue(next++, "$optional-origin", Void)), terminator.provenance);
					var result = aggregate(target, types.get(value.id), partsAt(target, value.id, here), here);
					target.terminator = new Located(Return(result), terminator.provenance);
				case Throw(value) if (components.exists(value.id)):
					var here:Located<IrInstruction> = new Located(ConstVoid(new IrValue(next++, "$optional-origin", Void)), terminator.provenance);
					target.terminator = new Located(Throw(box(target, value, here)), terminator.provenance);
				case Rethrow(value) if (components.exists(value.id)):
					var here:Located<IrInstruction> = new Located(ConstVoid(new IrValue(next++, "$optional-origin", Void)), terminator.provenance);
					target.terminator = new Located(Rethrow(box(target, value, here)), terminator.provenance);
				default:
			}
		}
		for (id => reads in pendingReads) {
			var target:IrBlock = cast copies.get(id);
			for (read in reads) target.instructions.push(read);
		}
		var debug = [for (binding in fn.debugBindings) if (!components.exists(binding.value.id) && !alias.exists(binding.value.id)) binding];
		debug = IrInliner.substitute(blocks, substitutions, debug);
		// Remove unobserved static closures after their calls become direct. An
		// optimized-out debug binding does not keep an allocation alive.
		var used:Map<Int, Bool> = [], removed:Map<Int, Bool> = [];
		for (block in blocks) {
			for (located in block.instructions) {
				for (input in IrOperands.inputs(located.value)) used.set(input.id, true);
				switch located.value { case Phi(_, inputs): for (input in inputs) used.set(input.value.id, true); default: }
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(v), Throw(v), Rethrow(v), Branch(v, _, _): used.set(v.id, true);
				case Jump(_):
			}
		}
		for (block in blocks) {
			var keep:Array<Located<IrInstruction>> = [];
			for (located in block.instructions) switch located.value {
				case StaticClosure(out, _) if (!used.exists(out.id)): removed.set(out.id, true);
				default: keep.push(located);
			}
			block.instructions.resize(0);
			for (located in keep) block.instructions.push(located);
		}
		debug = [for (binding in debug) if (!removed.exists(binding.value.id)) binding];
		var result = optional(fn.result) == null ? fn.result : Obj(wrapper(optional(fn.result)).name);
		return new IrFunction(clone ? PREFIX + fn.name : fn.name, args, result, blocks, debug, fn.inlineHint,
			clone ? compiler.ir.IrFunction.IrRetention.Reachable : fn.retention);
	}
}
