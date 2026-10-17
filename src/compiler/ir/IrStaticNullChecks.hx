package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Diagnose dereferencing a null static instead of letting native code read null + a field offset. */
class IrStaticNullChecks {
	public static function run(functions:Array<IrFunction>, ?objects:Array<IrObject>):Array<IrFunction> {
		var helpers:Map<String, IrFunction> = [];
		var result:Array<IrFunction> = [];
		var byName = [for (fn in functions) fn.name => fn],
			reachable:Map<String, Bool> = [],
			pending = ["__init"];
		var execution = new IrInitializationCalls(functions, objects);
		while (pending.length > 0) {
			var name = pending.pop();
			if (reachable.exists(name) || !byName.exists(name))
				continue;
			reachable.set(name, true);
			for (callee in execution.calls(byName.get(name)))
				pending.push(callee);
		}
		for (fn in functions) {
			if (!reachable.exists(fn.name)) {
				result.push(fn);
				continue;
			}
			var origins:Map<Int, String> = [], nextId = 0;
			for (argument in fn.arguments)
				nextId = Std.int(Math.max(nextId, argument.id + 1));
			for (block in fn.blocks)
				for (instruction in block.instructions) {
					var output = IrOperands.output(instruction.value);
					if (output != null)
						nextId = Std.int(Math.max(nextId, output.id + 1));
					switch instruction.value {
						case GlobalGet(value, name):
							origins.set(value.id, name);
						case _:
					}
				}
			// SSA casts and joins can carry a static to its eventual dereference.
			var changed = true;
			while (changed) {
				changed = false;
				for (block in fn.blocks)
					for (instruction in block.instructions) {
						var output = IrOperands.output(instruction.value);
						if (output == null || origins.exists(output.id))
							continue;
						var source:Null<String> = switch instruction.value {
							case SafeCast(_, value), ToDyn(_, value), ToVirtual(_, value): origins.get(value.id);
							case Phi(_, inputs):
								var name:Null<String> = null;
								for (input in inputs) {
									var origin = origins.get(input.value.id);
									if (origin == null || name != null && name != origin) {
										name = null;
										break;
									}
									name = origin;
								}
								name;
							case _: null;
						};
						if (source != null) {
							origins.set(output.id, source);
							changed = true;
						}
					}
			}
			var blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var copy = new IrBlock(block.id);
				copy.terminator = block.terminator;
				for (instruction in block.instructions) {
					var receiver:Null<IrValue> = switch instruction.value {
						case FieldGet(_, value, _), FieldSet(value, _, _), ArrayGet(_, value, _), ArraySet(value, _, _), ArraySize(_, value),
							IteratorNew(_, value), MethodCall(_, value, _, _), EnumIndex(_, value), EnumField(_, value, _, _): value;
						case _: null;
					};
					if (receiver != null && origins.exists(receiver.id)) {
						var name = origins.get(receiver.id),
							helperName = "__static$nonnull$" + name;
						if (!helpers.exists(name)) {
							var builder = new IrBuilder(),
								value = builder.argument("value", Dyn),
								missing = builder.createBlock(),
								present = builder.createBlock();
							builder.branch(builder.equal(value, builder.constNull(Dyn)), missing, present);
							builder.select(missing);
							builder.terminate(Throw(builder.toDyn(builder.constString('Cannot dereference null static "$name"'))));
							builder.select(present);
							builder.returnValue(builder.constVoid());
							helpers.set(name, new IrFunction(helperName, builder.arguments, Void, builder.blocks));
						}
						var boxed = new IrValue(nextId++, "staticReceiver", Dyn),
							unused = new IrValue(nextId++, "staticCheck", Void);
						copy.instructions.push(new Located(ToDyn(boxed, receiver), instruction.provenance));
						copy.instructions.push(new Located(Call(unused, helperName, [boxed]), instruction.provenance));
					}
					copy.instructions.push(instruction);
				}
				blocks.push(copy);
			}
			// Cached functions belong to the frontend; never instrument them in place.
			result.push(new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention));
		}
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			result.push(helpers.get(name));
		return result;
	}
}
