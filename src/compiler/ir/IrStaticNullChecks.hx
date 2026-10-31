package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Diagnose dereferencing a null static instead of letting native code read null + a field offset. */
class IrStaticNullChecks {
	/**
	 * `cache` keeps each instrumented copy and helper alive between compiles, so a function that did not change comes out
	 * as the same object; the inliner memoizes on function identity and would otherwise redo everything reachable from
	 * initialization on every compile.
	 */
	public static function run(functions:Array<IrFunction>, ?objects:Array<IrObject>, ?cache:IrStaticCheckCache):Array<IrFunction> {
		var helpers:Map<String, IrFunction> = [];
		var nextCopies:Map<String, {source:IrFunction, result:IrFunction, statics:Array<String>}> = [];
		var store = cache != null ? cache : new IrStaticCheckCache();
		var valueTypes:Map<String, Bool> = [], valueNames:Array<String> = [];
		if (objects != null) for (object in objects) if (object.isValue) { valueTypes.set(object.name, true); valueNames.push(object.name); }
		valueNames.sort(Reflect.compare);
		var valueShape = haxe.Json.stringify(valueNames);
		if (store.valueShape != valueShape) {
			store.copies = [];
			store.helpers = [];
			store.valueShape = valueShape;
		}
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
			var known = store.copies.get(fn.name);
			if (known != null && known.source == fn) {
				nextCopies.set(fn.name, known);
				for (name in known.statics)
					helpers.set(name, store.helpers.get(name));
				result.push(known.result);
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
							case SafeCast(_, value), ToDyn(_, value), ToVirtual(_, value), Upcast(_, value): origins.get(value.id);
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
			var blocks:Array<IrBlock> = [], used:Map<String, Bool> = [];
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
							valueType = switch receiver.type { case Obj(typeName) if (valueTypes.exists(typeName)): receiver.type; default: null; },
							helperName = valueType == null ? "__static$nonnull$" + name : "$static$nonnull$value$" + haxe.Json.stringify([name, Std.string(valueType)]);
						if (!helpers.exists(helperName)) {
							var knownHelper = store.helpers.get(helperName);
							if (knownHelper != null)
								helpers.set(helperName, knownHelper);
							else {
								var builder = new IrBuilder(),
									value = builder.argument("value", valueType == null ? Dyn : valueType),
									missing = builder.createBlock(),
									present = builder.createBlock();
								builder.branch(builder.equal(value, builder.constNull(value.type)), missing, present);
								builder.select(missing);
								builder.terminate(Throw(builder.toDyn(builder.constString('Cannot dereference null static "$name"'))));
								builder.select(present);
								builder.returnValue(builder.constVoid());
								var created = new IrFunction(helperName, builder.arguments, Void, builder.blocks);
								helpers.set(helperName, created);
								store.helpers.set(helperName, created);
							}
						}
						used.set(helperName, true);
						var actual = receiver;
						if (valueType == null) {
							actual = new IrValue(nextId++, "staticReceiver", Dyn);
							copy.instructions.push(new Located(ToDyn(actual, receiver), instruction.provenance));
						}
						var unused = new IrValue(nextId++, "staticCheck", Void);
						copy.instructions.push(new Located(Call(unused, helperName, [actual]), instruction.provenance));
					}
					copy.instructions.push(instruction);
				}
				blocks.push(copy);
			}
			// Cached functions belong to the frontend; never instrument them in place.
			var copied = new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention);
			nextCopies.set(fn.name, {source: fn, result: copied, statics: [for (name in used.keys()) name]});
			result.push(copied);
		}
		store.copies = nextCopies;
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			result.push(helpers.get(name));
		return result;
	}
}

/** What `IrStaticNullChecks` produced last time: each reachable function's instrumented copy, and the shared helpers. */
class IrStaticCheckCache {
	public var copies:Map<String, {source:IrFunction, result:IrFunction, statics:Array<String>}> = [];
	public var helpers:Map<String, IrFunction> = [];
	public var valueShape:String = "";

	public function new() {}
}
