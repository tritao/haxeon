package compiler.ir;

import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.Ir;

/**
 * Diagnose dereferencing a null static instead of letting native code read null + a field offset. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration): a dereference of a static is preceded in place by a call of the static's check.
 */
class IrStaticNullChecks {
	/**
	 * `functions` read as their bodies made with `types` (those of the functions' bodies when not given): a function that gets
	 * a check becomes its edited body, owned by the next stage; the checks come last, encoded.
	 *
	 * `cache` keeps each instrumented copy and helper alive between compiles, so a function that did not change comes out
	 * as the same object; the inliner memoizes on function identity and would otherwise redo everything reachable from
	 * initialization on every compile.
	 */
	public static function run(functions:Array<IrFunction>, ?objects:Array<IrObject>, ?cache:IrStaticCheckCache,
			?types:IrTypeIds, ?builder:IrBodyBuilder):Array<IrFunction> {
		if (types == null)
			types = IrTypeIds.ofFunctions(functions);
		var helpers:Map<String, IrFunction> = [];
		var nextCopies:Map<String, {source:IrFunction, result:IrFunction, statics:Array<String>}> = [];
		var store = cache != null ? cache : new IrStaticCheckCache();
		var valueTypes:Map<String, Bool> = [], valueNames:Array<String> = [];
		if (objects != null)
			for (object in objects)
				if (object.isValue) {
					valueTypes.set(object.name, true);
					valueNames.push(object.name);
				}
		valueNames.sort(Reflect.compare);
		var valueShape = haxe.Json.stringify(valueNames);
		if (store.valueShape != valueShape) {
			store.copies = [];
			store.helpers = [];
			store.valueShape = valueShape;
		}
		var result:Array<IrFunction> = [];
		var byName = new IrFunctionIndex("static-null-checks", functions),
			reachable:Map<String, Bool> = [],
			pending = ["__init"];
		var execution = new IrInitializationCalls(functions, types, objects, builder);
		while (pending.length > 0) {
			var name = pending.pop();
			if (reachable.exists(name) || !byName.exists(name))
				continue;
			reachable.set(name, true);
			for (callee in execution.calls(name))
				pending.push(callee);
		}
		// The check of `name`, for a receiver of `valueType` (a value object) or any other (null).
		function helperFor(name:String, valueType:Null<IrType>):String {
			var helperName = valueType == null ? "__static$nonnull$" + name : "$static$nonnull$value$"
				+ haxe.Json.stringify([name, Std.string(valueType)]);
			if (!helpers.exists(helperName)) {
				var knownHelper = store.helpers.get(helperName);
				if (knownHelper != null)
					helpers.set(helperName, knownHelper);
				else {
					var created = check(helperName, name, valueType);
					created.bodyIn(types, builder);
					// A session's cache keeps it.
					if (cache != null)
						created.freezeBody(builder);
					helpers.set(helperName, created);
					store.helpers.set(helperName, created);
				}
			}
			return helperName;
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
			var body = fn.bodyIn(types, builder);
			// A session's cache keeps `fn` as its copy's source, so the copy is made on a copy.
			if (cache != null)
				body = fn.freezeBody(builder);
			var origins = staticOrigins(body);
			var used:Map<String, Bool> = [], edited:Null<IrBody> = null;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var nextRow = body.nextRow(row);
					for (index in 0...receiverCount(body, row)) {
						var receiver = receiverAt(body, row, index), name = origins.get(receiver);
						if (name == null)
							continue;
						var receiverType = body.valueType(receiver),
							valueType = switch receiverType {
								case Obj(typeName) if (valueTypes.exists(typeName)): receiverType;
								default: null;
							};
						var helperName = helperFor(name, valueType);
						used.set(helperName, true);
						// Cached functions belong to the frontend; never instrument them in place.
						if (edited == null)
							edited = body.forEditing(builder);
						var actual = receiver;
						if (valueType == null) {
							actual = edited.newValue("staticReceiver", edited.typeId(Dyn));
							edited.beginRow();
							edited.pushOperand(receiver);
							edited.linkBefore(block, row,
								edited.endRow(IrOpcode.ToDyn, actual, 0, edited.provenance(row)));
						}
						var unused = edited.newValue("staticCheck", edited.typeId(Void));
						edited.beginRow();
						edited.pushOperand(actual);
						edited.linkBefore(block, row,
							edited.endRow(IrOpcode.Call, unused, IrSymbol.of(helperName).id, edited.provenance(row)));
					}
					row = nextRow;
				}
			}
			// A function with no static receiver gets no check, and stays the frontend's own object.
			var copied = edited == null ? fn : IrFunction.ofOwnedBody(edited);
			if (cache != null && copied != fn)
				copied.freezeBody(builder);
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

	/** By value id, the static each value of `body` holds: what a static's read gives, through SSA casts and joins. */
	static function staticOrigins(body:IrBody):Map<Int, String> {
		var origins:Map<Int, String> = [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.GlobalGet)
					origins.set(body.output(row), body.symbol(row).name);
				row = body.nextRow(row);
			}
		}
		// SSA casts and joins can carry a static to its eventual dereference.
		var changed = true;
		while (changed) {
			changed = false;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var output:Int = body.output(row);
					if (output >= 0 && !origins.exists(output)) {
						var source:Null<String> = switch body.opcode(row) {
							case IrOpcode.SafeCast, IrOpcode.ToDyn, IrOpcode.ToVirtual, IrOpcode.Upcast:
								origins.get(body.operand(row, 0));
							case IrOpcode.Phi:
								var name:Null<String> = null;
								for (index in 0...body.operandCount(row)) {
									var origin = origins.get(body.operand(row, index));
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
							origins.set(output, source);
							changed = true;
						}
					}
					row = body.nextRow(row);
				}
			}
		}
		return origins;
	}

	/** How many values `row` dereferences: 0, 1, or 2 for an optional field copy. */
	static function receiverCount(body:IrBody, row:Int):Int {
		return switch body.opcode(row) {
			case IrOpcode.FieldGet, IrOpcode.FieldSet, IrOpcode.ArrayGet, IrOpcode.ArraySet, IrOpcode.ArraySize,
				IrOpcode.IteratorNew, IrOpcode.MethodCall, IrOpcode.EnumIndex, IrOpcode.EnumField: 1;
			case IrOpcode.Call if (body.operandCount(row) == 2
				&& IrOptionalFieldStorage.isCopyName(body.symbol(row).name)): 2;
			case _: 0;
		};
	}

	/**
	 * The `index`th value `row` dereferences, in the order it reads them: a copy reads the source before it writes the
	 * destination, even when both are null statics.
	 */
	static inline function receiverAt(body:IrBody, row:Int, index:Int):IrValueId
		return body.opcode(row) == IrOpcode.Call ? body.operand(row, 1 - index) : body.operand(row, 0);

	/** The function that throws when the static `name` is null, for a receiver of `valueType` (a value object) or any other. */
	static function check(helperName:String, name:String, valueType:Null<IrType>):IrFunction {
		var builder = new IrBuilder(),
			value = builder.argument("value", valueType == null ? Dyn : valueType),
			missing = builder.createBlock(),
			present = builder.createBlock();
		builder.branch(builder.equal(value, builder.constNull(value.type)), missing, present);
		builder.select(missing);
		builder.terminate(Throw(builder.toDyn(builder.constString('Cannot dereference null static "$name"'))));
		builder.select(present);
		builder.returnValue(builder.constVoid());
		return new IrFunction(helperName, builder.arguments, Void, builder.blocks,
			Provider(TypeKey.of(valueType == null ? Dyn : valueType),
			ProviderOperations.detailed(ProviderOperation.ReceiverCheck, helperName)));
	}
}

/** What `IrStaticNullChecks` produced last time: each reachable function's instrumented copy, and the shared helpers. */
class IrStaticCheckCache {
	public var copies:Map<String, {source:IrFunction, result:IrFunction, statics:Array<String>}> = [];
	public var helpers:Map<String, IrFunction> = [];
	public var valueShape:String = "";

	public function new() {}
}
