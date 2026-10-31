package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.SourceProvenance.Located;

private typedef ValuePhiPlan = {final output:IrValue; final inputs:Array<IrPhiInput>;}

/** Split a value phi into scalar snapshots when every incoming value is known to exist. */
class IrValuePhiScalarization {
	public static function rewrite(program:IrProgram):Void {
		var objects:Map<String, IrObject> = [for (object in program.objects) object.name => object];
		var table = IrObjectTable.of(objects), layouts = new IrInlineValueLayout(table);
		program.functions = [for (fn in program.functions) rewriteFunction(fn, objects, table, layouts)];
	}

	static function rewriteFunction(fn:IrFunction, objects:Map<String, IrObject>, table:IrObjectTable,
			layouts:IrInlineValueLayout):IrFunction {
		function valueName(type:IrType):Null<String> return switch type {
			case Obj(name) if (objects.exists(name) && objects.get(name).isValue): name;
			default: null;
		};
		var known:Map<Int, Bool> = [], next = 0, byId:Map<Int, IrBlock> = [];
		for (arg in fn.arguments) if (arg.id >= next) next = arg.id + 1;
		for (block in fn.blocks) {
			byId.set(block.id, block);
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null && out.id >= next) next = out.id + 1;
				switch located.value {
					case NewObject(out, _) if (valueName(out.type) != null): known.set(out.id, true);
					default:
				}
			}
		}
		var plans:Map<Int, ValuePhiPlan> = [];
		function isolated(input:IrPhiInput, destination:Int, output:IrValue):Bool {
			for (block in fn.blocks) {
				for (located in block.instructions) {
					switch located.value {
						case Phi(other, inputs):
							for (entry in inputs) if (entry.value.id == input.value.id
									&& (other.id != output.id || block.id != destination || entry.block != input.block)) return false;
						default:
					}
					var used = false;
					for (operand in IrOperands.inputs(located.value)) if (operand.id == input.value.id) used = true;
					if (!used) continue;
					if (block.id != input.block) return false;
					switch located.value {
						case FieldGet(_, owner, _) if (owner.id == input.value.id):
						case FieldSet(owner, _, value) if (owner.id == input.value.id && value.id != input.value.id):
						default: return false;
					}
				}
				if (block.terminator != null) switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (value.id == input.value.id): return false;
					default:
				}
			}
			return true;
		}
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Phi(out, inputs) if (valueName(out.type) != null):
				var valid = inputs.length > 0;
				for (input in inputs) {
					var pred = byId.get(input.block), terminator = pred == null ? null : pred.terminator;
					if (terminator == null || !known.exists(input.value.id) || !Type.enumEq(input.value.type, out.type)
							|| !isolated(input, block.id, out)) valid = false;
					else switch terminator.value { case Jump(id) if (id == block.id): default: valid = false; }
				}
				if (valid) plans.set(out.id, {output: out, inputs: inputs});
			default:
		}
		if (!plans.keys().hasNext()) return fn;
		var blocks:Array<IrBlock> = [], copies:Map<Int, IrBlock> = [];
		for (block in fn.blocks) { var copy = new IrBlock(block.id); copy.terminator = block.terminator; blocks.push(copy); copies.set(block.id, copy); }
		function declared(type:IrType, field:String):IrObjectField {
			var name = switch type { case Obj(value): value; default: throw "Invalid value phi field"; };
			while (name != null) {
				var object = objects.get(name);
				if (object == null) break;
				for (candidate in object.fields) if (candidate.name == field) return candidate;
				name = object.base;
			}
			throw 'Missing value phi field "$field"';
		}
		var deferred:Map<Int, Array<Located<IrInstruction>>> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Phi(out, _) if (plans.exists(out.id)):
				var plan:ValuePhiPlan = cast plans.get(out.id), shape = layouts.slots(out.type), phis:Array<Array<IrPhiInput>> = [for (_ in shape) []];
				for (input in plan.inputs) {
					var predecessor:IrBlock = cast copies.get(input.block);
					for (index in 0...shape.length) {
						var current = input.value, slot = shape[index];
						for (partIndex in 0...slot.path.length) {
							var part = slot.path[partIndex], field = declared(current.type, part), optional = switch field.type {
								case Nullable(Obj(name)): objects.exists(name) && objects.get(name).isValue;
								default: false;
							};
							if (optional) {
								var sub:IrInlineValueSlot = {path: slot.path.slice(partIndex + 1), type: slot.type, isPresence: slot.isPresence, nativeLayout: slot.nativeLayout};
								var read = new IrValue(next++, "$value-phi-read", slot.type);
								predecessor.instructions.push(new Located(FieldGet(read, current, IrInlineValueLayout.slotName(part, sub)), located.provenance));
								current = read; break;
							}
							var read = new IrValue(next++, "$value-phi-read", field.type);
							predecessor.instructions.push(new Located(FieldGet(read, current, part), located.provenance)); current = read;
						}
						phis[index].push({block: input.block, value: current});
					}
				}
				var setup:Array<Located<IrInstruction>> = [], scalar:Array<IrValue> = [];
				for (slot in shape) scalar.push(new IrValue(next++, "$value-phi-slot", slot.type));
				setup.push(new Located(NewObject(out, valueName(out.type)), located.provenance));
				for (index in 0...shape.length) {
					var current = out, path = shape[index].path;
					for (partIndex in 0...path.length) {
						var part = path[partIndex], field = declared(current.type, part), optional = switch field.type {
							case Nullable(Obj(name)): objects.exists(name) && objects.get(name).isValue;
							default: false;
						};
						if (optional) {
							var slot = shape[index], sub:IrInlineValueSlot = {path: path.slice(partIndex + 1), type: slot.type, isPresence: slot.isPresence, nativeLayout: slot.nativeLayout};
							setup.push(new Located(FieldSet(current, IrInlineValueLayout.slotName(part, sub), scalar[index]), located.provenance)); break;
						}
						if (partIndex == path.length - 1) setup.push(new Located(FieldSet(current, part, scalar[index]), located.provenance));
						else {
							var child = new IrValue(next++, "$value-phi-child", field.type);
							setup.push(new Located(FieldGet(child, current, part), located.provenance)); current = child;
						}
					}
				}
				var list = deferred.get(block.id); if (list == null) { list = []; deferred.set(block.id, list); }
				for (item in setup) list.push(item);
				// The scalar phi values are the operands used by the deferred construction.
				var target:IrBlock = cast copies.get(block.id);
				for (index in 0...shape.length) target.instructions.push(new Located(Phi(scalar[index], phis[index]), located.provenance));
			default:
		}
		// Reads must follow each predecessor's original instructions. Phis must precede ordinary instructions.
		for (block in fn.blocks) {
			var target:IrBlock = cast copies.get(block.id), reads = target.instructions.copy(), phiInstructions:Array<Located<IrInstruction>> = [], preReads:Array<Located<IrInstruction>> = [];
			for (item in reads) switch item.value { case Phi(_, _): phiInstructions.push(item); default: preReads.push(item); }
			target.instructions.resize(0);
			for (located in block.instructions) switch located.value {
				case Phi(out, _) if (plans.exists(out.id)):
				case Phi(_, _): target.instructions.push(located);
				default:
			}
			for (item in phiInstructions) target.instructions.push(item);
			var setup = deferred.get(block.id); if (setup != null) for (item in setup) target.instructions.push(item);
			for (located in block.instructions) switch located.value { case Phi(_, _): default: target.instructions.push(located); }
			for (item in preReads) target.instructions.push(item);
		}
		var candidate = new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention);
		var optimized = IrScalarReplacement.rewrite(candidate, table, true, true);
		for (block in optimized.blocks) for (located in block.instructions) switch located.value {
			case NewObject(out, _) if (plans.exists(out.id)): return fn;
			default:
		}
		return optimized;
	}
}
