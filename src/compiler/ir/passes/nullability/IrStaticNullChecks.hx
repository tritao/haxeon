package compiler.ir.passes.nullability;

import compiler.core.InternalError;
import compiler.ir.analysis.IrInitializationCalls;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrValueId;
import compiler.ir.model.TypeKey;
import compiler.ir.analysis.IrInitializationCalls.IrInitCalls;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemo.IrLineage;

import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.model.Ir;

/**
 * Diagnose dereferencing a null static instead of letting native code read null + a field offset. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration), per function (`IrFunctionPass`): in a function that initialization can call
 * (`IrInitializationCalls`, from `__init`), a dereference of a static is preceded in place by a call of the static's check. The
 * rewrite reads whether the function is reached (`REACHED`) and whether each receiver's object is a value (`VALUE`), and asks for
 * the check of each static by its name and the receiver's type; the checks come last, by name.
 */
@:nullSafety(Strict)
class IrStaticNullChecks implements IrFunctionPass {
	public static inline final STAGE = "static-null-checks";

	/** Fact: whether initialization can call the function named by the key. */
	static inline final REACHED = 0;

	/** Fact: whether the object named by the key is a value. */
	static inline final VALUE = 1;

	/** Request kinds: the check of a static for any receiver, and for a value object's. */
	static inline final ANY = 0;

	static inline final OF_VALUE = 1;

	// Summary bits: the function reads a static; it stores something the walk of what initialization calls follows.
	static inline final READS_STATIC = 1;

	static inline final STORES = 2;

	final objects:Null<Array<IrObject>>;
	final valueTypes:Map<String, Bool> = [];
	final builder:Null<IrBodyBuilder>;
	final lineage:Null<IrLineage>;
	final checks:Bool;

	/** By name, the checks asked for: the static and the receiver's value type, or null for any other receiver. */
	final helpers:Map<String, {name:String, valueType:Null<IrType>}> = [];

	var reached:Map<String, Bool> = [];

	/** A run over functions with `objects`; in a session with `lineage`. */
	public function new(objects:Null<Array<IrObject>>, ?builder:IrBodyBuilder, ?lineage:IrLineage,
			checks = false) {
		this.objects = objects;
		if (objects != null)
			for (object in objects)
				if (object.isValue)
					valueTypes.set(object.name, true);
		this.builder = builder;
		this.lineage = lineage;
		this.checks = checks;
	}

	/** `functions` with the checks, without a memo: read as their bodies. */
	public static function run(functions:Array<IrFunction>, ?objects:Array<IrObject>,
			?builder:IrBodyBuilder):Array<IrFunction>
		return IrFunctionStages.apply(STAGE, new IrStaticNullChecks(objects, builder), functions);

	public function summarize(fn:IrFunction):Int {
		var body = fn.encodedBody(builder),
			flags = IrInitCalls.stores(fn, builder, lineage).relevant ? STORES : 0;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.GlobalGet)
					return flags | READS_STATIC;
				row = body.nextRow(row);
			}
		}
		return flags;
	}

	/** The functions initialization may call, from what the functions that store something give (`STORES`). */
	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {
		var stores:Array<Null<IrInitCalls>> = [
			for (index in 0...functions.length)
				summaries[index] & STORES != 0 ? IrInitCalls.stores(functions[index], builder, lineage) : null
		];
		var calls = new IrInitializationCalls(functions, stores, fn -> IrInitCalls.calls(fn, builder, lineage),
			names.get, objects);
		reached = calls.reachable("__init", names.exists);
	}

	public function fact(kind:Int, key:String):Int
		return switch kind {
			case REACHED: reached.exists(key) ? 1 : 0;
			case _: valueTypes.exists(key) ? 1 : 0;
		};

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		if (summary & READS_STATIC == 0 || reader.read(REACHED, fn.name) == 0)
			return fn;
		var body = fn.encodedBody(builder);
		var origins = staticOrigins(body);
		var edited:Null<IrBody> = null;
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
							case Obj(typeName) if (reader.read(VALUE, typeName) == 1): receiverType;
							default: null;
						};
					reader.request(valueType == null ? ANY : OF_VALUE, valueType ?? Dyn, name);
					// A function given to the stage belongs to the stage before; it is never instrumented in place.
					if (edited == null)
						edited = body.forEditing(builder);
					var actual = receiver;
					if (valueType == null) {
						actual = edited.newValue("staticReceiver", edited.typeId(Dyn));
						edited.beginRow();
						edited.pushOperand(receiver);
						edited.linkBefore(block, row, edited.endRow(IrOpcode.ToDyn, actual, 0, edited.provenance(row)));
					}
					var unused = edited.newValue("staticCheck", edited.typeId(Void));
					edited.beginRow();
					edited.pushOperand(actual);
					edited.linkBefore(block, row,
						edited.endRow(IrOpcode.Call, unused, IrSymbol.of(helperName(name, valueType)).id,
						edited.provenance(row)));
				}
				row = nextRow;
			}
		}
		// A function with no static receiver gets no check, and stays the object it was given.
		return edited == null ? fn : IrFunction.ofOwnedBody(edited);
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void {
		if (name == null)
			throw new InternalError("A static null check is asked for by the static's name");
		var valueType = kind == OF_VALUE ? type : null;
		helpers.set(helperName(name, valueType), {name: name, valueType: valueType});
	}

	public function finish(functions:Array<IrFunction>):Array<IrFunction> {
		var result = functions.copy(), names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (helperName in names) {
			var helper = helpers.get(helperName);
			if (helper != null)
				result.push(IrFunctionStages.derived(STAGE, helperName, this, IrFunctionStages.FROM_NAME, lineage,
					checks,
					builder, _ -> {
						var made = check(helperName, helper.name, helper.valueType);
						made.encodedBody(builder);
						made;
					}));
		}
		return result;
	}

	/** The name of the check of the static `name`, for a receiver of `valueType` (a value object) or any other (null). */
	static function helperName(name:String, valueType:Null<IrType>):String
		return valueType == null ? "__static$nonnull$" + name : "$static$nonnull$value$"
			+ haxe.Json.stringify([name, Std.string(valueType)]);

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
