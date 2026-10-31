package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.SourceProvenance.Located;

/** Experimental direct-call specialization for nonescaping scalar value arguments on HashLink. */
class IrHlScalarArguments {
	public static inline final PREFIX = "$hl:scalar-arguments:";

	public static function rewrite(program:IrProgram):Void {
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var methods:Map<String, Null<String>> = [];
		var candidates:Map<String, IrFunction> = [];
		for (fn in program.functions) {
			if (StringTools.startsWith(fn.name, "$") && !StringTools.startsWith(fn.name, "$lambda:")
				&& !StringTools.startsWith(fn.name, "$generic:") && !StringTools.startsWith(fn.name, "$value$equality:") && !StringTools.startsWith(fn.name, IrOptionalScalarFlow.PREFIX)
				&& !IrOptionalValueFlow.isBoundaryHelper(fn.name)) continue;
			var hasValue = isValue(fn.result, objects), eligible = true, argumentCount = 0;
			if (hasValue) {
				if (!hasScalarLayout(fn.result, objects)) eligible = false;
				argumentCount += slots(fn.result, objects).length;
			}
			for (arg in fn.arguments) if (isValue(arg.type, objects)) {
				hasValue = true;
				if ((arg.name == "this" && !receiverReadOnly(fn)) || !hasScalarLayout(arg.type, objects)) eligible = false;
				argumentCount += slots(arg.type, objects).length;
			} else argumentCount++;
			// The HashLink JIT accepts at most 256 arguments per emitted call. Dynamic calls retain the original ABI.
			if (argumentCount > 256) eligible = false;
			if (hasValue && eligible) candidates.set(fn.name, fn);
		}
		var methodNames:Map<String, Bool> = [];
		for (object in program.objects) for (method in object.methods)
			if (candidates.exists(method.functionName)) methodNames.set(method.name, true);
		// Do not redirect a call if reconstructing its value arguments would allocate in the clone. In particular,
		// handler edges can keep an otherwise field-only value alive across blocks.
		var clones:Map<String, IrFunction> = [], changed = true;
		while (changed) {
			changed = false;
			clones = [];
			for (fn in program.functions) if (candidates.exists(fn.name)) {
				var retained = false;
				for (arg in fn.arguments) if (isValue(arg.type, objects) && !fieldOnly(fn, arg, objects, candidates, methods, methodNames)) retained = true;
				var specialized = IrScalarReplacement.rewrite(rewriteCalls(clone(fn, objects), candidates, objects, methods, methodNames), IrObjectTable.of(objects), true, true);
				var scalarLocals = new compiler.ir.hl.HlScalarValueLocals(specialized, objects, _ -> 0);
				for (block in specialized.blocks) for (located in block.instructions) switch located.value {
					case NewObject(out, name):
						for (arg in fn.arguments) if (isValue(arg.type, objects) && out.id == arg.id && scalarLocals.get(out) == null) retained = true;
						if (isValue(fn.result, objects) && Type.enumEq(fn.result, Obj(name)) && scalarLocals.get(out) == null) retained = true;
					case Call(out, _, _) | MethodCall(out, _, _, _) | CallClosure(out, _, _):
						if (isValue(fn.result, objects) && isValue(out.type, objects)) retained = true;
					default:
				}
				if (retained) { candidates.remove(fn.name); changed = true; } else clones.set(fn.name, specialized);
			}
		}
		if (!candidates.keys().hasNext()) return;
		var rewritten:Array<IrFunction> = [];
		for (fn in program.functions) rewritten.push(rewriteCalls(fn, candidates, objects, methods, methodNames));
		for (fn in program.functions) if (candidates.exists(fn.name))
			rewritten.push(clones.get(fn.name));
		program.functions = rewritten;
	}

	static function isValue(type:IrType, objects:Map<String, IrObject>):Bool
		return switch type { case Obj(name): objects.exists(name) && objects.get(name).isValue; default: false; };

	static function hasScalarLayout(type:IrType, objects:Map<String, IrObject>):Bool {
		for (slot in slots(type, objects)) if (slot.isPresence) return false;
		return true;
	}

	static function slots(type:IrType, objects:Map<String, IrObject>):Array<IrInlineValueSlot>
		return new IrInlineValueLayout(IrObjectTable.of(objects)).slots(type);

	static function fieldOnly(fn:IrFunction, arg:IrValue, objects:Map<String, IrObject>, candidates:Map<String, IrFunction>,
			methods:Map<String, Null<String>>, methodNames:Map<String, Bool>):Bool {
		var aliases:Map<Int, Bool> = [arg.id => true], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case FieldGet(out, receiver, _) if (aliases.exists(receiver.id) && isValue(out.type, objects) && !aliases.exists(out.id)):
					aliases.set(out.id, true); changed = true;
				default:
			}
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, inputs):
						for (input in inputs) if (aliases.exists(input.value.id)) return false;
					default:
				}
				var uses = [for (input in IrOperands.inputs(located.value)) if (aliases.exists(input.id)) input];
				if (uses.length == 0) continue;
				switch located.value {
					case FieldGet(_, receiver, _) if (aliases.exists(receiver.id)):
					case FieldSet(receiver, _, value) if (aliases.exists(receiver.id) && !aliases.exists(value.id)):
					case Call(_, name, arguments) if (candidates.exists(name)):
						var target = candidates.get(name);
						for (index in 0...arguments.length)
							if (aliases.exists(arguments[index].id) && !isValue(target.arguments[index].type, objects)) return false;
					case MethodCall(_, receiver, method, arguments) if (!aliases.exists(receiver.id) && methodNames.exists(method)):
						var name = resolveMethod(receiver.type, method, objects, methods);
						if (name == null || !candidates.exists(name)) return false;
						var target = candidates.get(name);
						for (index in 0...arguments.length)
							if (aliases.exists(arguments[index].id) && !isValue(target.arguments[index + 1].type, objects)) return false;
					default: return false;
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value) if (aliases.exists(value.id) && !isValue(fn.result, objects)): return false;
				case Throw(value), Rethrow(value), Branch(value, _, _) if (aliases.exists(value.id)): return false;
				default:
			}
		}
		return true;
	}

	/** A place receiver may be changed by aliases during a callback, so only specialize a receiver that cannot write or call out. */
	static function receiverReadOnly(fn:IrFunction):Bool {
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(_, _, _) | CNativeCall(_, _, _) | MethodCall(_, _, _, _) | CallClosure(_, _, _)
				| GlobalSet(_, _) | FieldSet(_, _, _) | ArraySet(_, _, _) | MemoryStore(_, _, _)
				| InstanceClosure(_, _, _) | StaticClosure(_, _): return false;
			default:
		}
		return true;
	}

	static function nextId(fn:IrFunction):Int {
		var max = -1;
		for (arg in fn.arguments) if (arg.id > max) max = arg.id;
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null && out.id > max) max = out.id;
		}
		return max + 1;
	}

	static function clone(fn:IrFunction, objects:Map<String, IrObject>):IrFunction {
		var next = nextId(fn), args:Array<IrValue> = [], prefix:Array<Located<IrInstruction>> = [];
		var origin = SourceProvenance.generated("hl-scalar-argument");
		for (arg in fn.arguments) {
			if (!isValue(arg.type, objects)) { args.push(arg); continue; }
			var name = switch arg.type { case Obj(name): name; default: throw "Invalid scalar argument"; };
			prefix.push(new Located(NewObject(arg, name), origin));
			for (slot in slots(arg.type, objects)) {
				var leaf = new IrValue(next++, arg.name + "." + slot.path.join("."), slot.type);
				args.push(leaf);
				var target = arg;
				for (index in 0...slot.path.length - 1) {
					var field = fieldOf(target.type, slot.path[index], objects), child = new IrValue(next++, field.name, field.type);
					prefix.push(new Located(FieldGet(child, target, field.name), origin)); target = child;
				}
				prefix.push(new Located(FieldSet(target, slot.path[slot.path.length - 1], leaf), origin));
			}
		}
		var returnSlots = isValue(fn.result, objects) ? slots(fn.result, objects) : [], outputs:Array<IrValue> = [];
		for (slot in returnSlots) {
			var output = new IrValue(next++, "$hl:result:" + slot.path.join("."), IrHlScalarRef.type(slot.type));
			outputs.push(output); args.push(output);
		}
		var blocks:Array<IrBlock> = [];
		for (index in 0...fn.blocks.length) {
			var block = fn.blocks[index], copy = new IrBlock(block.id);
			if (index == 0) for (instruction in prefix) copy.instructions.push(instruction);
			for (instruction in block.instructions) copy.instructions.push(instruction);
			var terminator = block.terminator;
			copy.terminator = terminator;
			if (returnSlots.length > 0 && terminator != null) switch terminator.value {
				case Return(value):
					var leaves:Array<IrValue> = [];
					for (slot in returnSlots) {
						var current = value;
						for (part in slot.path) {
							var field = fieldOf(current.type, part, objects), leaf = new IrValue(next++, part, field.type);
							copy.instructions.push(new Located(FieldGet(leaf, current, part), terminator.provenance)); current = leaf;
						}
						leaves.push(current);
					}
					for (slot in 0...outputs.length) {
						var ignored = new IrValue(next++, "$hl:result-store", Void);
						copy.instructions.push(new Located(Call(ignored, IrHlScalarRef.STORE, [outputs[slot], leaves[slot]]), terminator.provenance));
					}
					var done = new IrValue(next++, "$hl:result-done", Void);
					copy.instructions.push(new Located(ConstVoid(done), terminator.provenance));
					copy.terminator = new Located(Return(done), terminator.provenance);
				default:
			}
			blocks.push(copy);
		}
		return new IrFunction(PREFIX + fn.name, args, returnSlots.length > 0 ? Void : fn.result, blocks, fn.debugBindings, fn.inlineHint);
	}

	static function rewriteCalls(fn:IrFunction, candidates:Map<String, IrFunction>, objects:Map<String, IrObject>,
			methods:Map<String, Null<String>>, methodNames:Map<String, Bool>):IrFunction {
		var next = nextId(fn), changed = false, blocks:Array<IrBlock> = [];
		var closures:Map<Int, {name:String, receiver:Null<IrValue>}> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case StaticClosure(out, name) if (candidates.exists(name)):
				closures.set(out.id, {name: name, receiver: null});
			case InstanceClosure(out, name, receiver) if (candidates.exists(name)):
				closures.set(out.id, {name: name, receiver: receiver});
			default:
		}
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = switch located.value {
					case CallClosure(out, closure, arguments) if (closures.exists(closure.id)):
						var binding = closures.get(closure.id);
						Call(out, binding.name, binding.receiver == null ? arguments : [binding.receiver].concat(arguments));
					case MethodCall(out, receiver, method, arguments) if (methodNames.exists(method)):
						var name = resolveMethod(receiver.type, method, objects, methods);
						if (name == null || !candidates.exists(name)) located.value;
						else {
							var checked = new IrValue(next++, "$hl:receiver-check", Void);
							copy.instructions.push(new Located(Call(checked, IrHlScalarRef.CHECK_RECEIVER, [receiver]), located.provenance));
							Call(out, name, [receiver].concat(arguments));
						}
					default: located.value;
				};
				switch instruction {
				case Call(out, name, arguments) if (candidates.exists(name)):
					var target = candidates.get(name), expanded:Array<IrValue> = [];
					for (index in 0...arguments.length) {
						var arg = arguments[index];
						if (!isValue(target.arguments[index].type, objects)) { expanded.push(arg); continue; }
						for (slot in slots(arg.type, objects)) {
							var current = arg;
							for (part in slot.path) {
								var field = fieldOf(current.type, part, objects), leaf = new IrValue(next++, arg.name + "." + part, field.type);
								copy.instructions.push(new Located(FieldGet(leaf, current, part), located.provenance)); current = leaf;
							}
							expanded.push(current);
						}
					}
					var returnSlots = isValue(target.result, objects) ? slots(target.result, objects) : [], references:Array<IrValue> = [];
					for (slot in returnSlots) {
						var zero = new IrValue(next++, "$hl:result-zero", slot.type), reference = new IrValue(next++, "$hl:result-ref", IrHlScalarRef.type(slot.type));
						var init:IrInstruction = switch slot.type {
							case I32, I64: ConstInt(zero, 0);
							case F32, F64: ConstFloat(zero, 0.0);
							case Bool: ConstBool(zero, false);
							default: ConstNull(zero);
						};
						copy.instructions.push(new Located(init, located.provenance));
						copy.instructions.push(new Located(Call(reference, IrHlScalarRef.ADDRESS, [zero]), located.provenance));
						references.push(reference); expanded.push(reference);
					}
					if (returnSlots.length == 0) copy.instructions.push(new Located(Call(out, PREFIX + name, expanded), located.provenance));
					else {
						var ignored = new IrValue(next++, "$hl:result-call", Void);
						copy.instructions.push(new Located(Call(ignored, PREFIX + name, expanded), located.provenance));
						var typeName = switch out.type { case Obj(value): value; default: throw "Invalid scalar result"; };
						copy.instructions.push(new Located(NewObject(out, typeName), located.provenance));
						for (index in 0...returnSlots.length) {
							var slot = returnSlots[index], leaf = new IrValue(next++, "$hl:result-leaf", slot.type), current = out;
							copy.instructions.push(new Located(Call(leaf, IrHlScalarRef.LOAD, [references[index]]), located.provenance));
							for (pathIndex in 0...slot.path.length - 1) {
								var field = fieldOf(current.type, slot.path[pathIndex], objects), child = new IrValue(next++, field.name, field.type);
								copy.instructions.push(new Located(FieldGet(child, current, field.name), located.provenance)); current = child;
							}
							copy.instructions.push(new Located(FieldSet(current, slot.path[slot.path.length - 1], leaf), located.provenance));
						}
					}
					changed = true;
				default: copy.instructions.push(located);
				}
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	static function fieldOf(type:IrType, name:String, objects:Map<String, IrObject>):IrObjectField {
		var objectName = switch type { case Obj(value): value; default: throw "Invalid scalar field owner"; };
		var object = objects.get(objectName);
		if (object != null) for (field in object.fields) if (field.name == name) return field;
		throw 'Missing scalar field $objectName.$name';
	}

	static function resolveMethod(type:IrType, method:String, objects:Map<String, IrObject>, cache:Map<String, Null<String>>):Null<String> {
		var name = switch type { case Obj(value): value; default: return null; };
		var root = objects.get(name);
		if (root == null) return null;
		if (root.isValue) return implementation(name, method, objects);
		var key = name.length + ":" + name + method;
		if (cache.exists(key)) return cache.get(key);
		var target = implementation(name, method, objects);
		if (target != null) for (object in objects) {
			var parent:Null<String> = object.name, depth = 0;
			while (parent != null && parent != name && depth++ < 256) {
				var entry = objects.get(parent);
				parent = entry == null ? null : entry.base;
			}
			if (depth >= 256 || (parent == name && implementation(object.name, method, objects) != target)) { target = null; break; }
		}
		cache.set(key, target);
		return target;
	}

	static function implementation(typeName:String, method:String, objects:Map<String, IrObject>):Null<String> {
		var name:Null<String> = typeName, depth = 0;
		while (name != null && depth++ < 256) {
			var object = objects.get(name);
			if (object == null) return null;
			for (entry in object.methods) if (entry.name == method) return entry.functionName;
			name = object.base;
		}
		return null;
	}
}
