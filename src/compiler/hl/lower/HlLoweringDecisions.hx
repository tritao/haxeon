package compiler.hl.lower;

import compiler.core.InternalError;
import compiler.ir.model.Ir.IrCNative;
import compiler.ir.model.Ir.IrScalarStorage;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrValueId;

/** What a call lowers to in both HashLink backends (`HlLoweringDecisions.classifyCall`). */
enum HlCallKind {
	/** `IrReceiverCheck`: a null check of the receiver, unless proved non-null. */
	ReceiverCheck;

	/** `IrReceiverCheck.STRING_LENGTH`: the string's length field, read after a null check unless proved non-null. */
	StringLength;

	/** `IrReferenceIdentity`: whether two references are the same object. */
	ReferenceIdentity;

	/** `IrExactTypeFacts.TEST`: whether an object's type is exactly a class. */
	ExactTypeTest;

	/** `IrScalarWordBits`: a scalar moved into or out of a word, unchanged. */
	WordBits;

	/** `IrValueLaneReference`: a reference moved into or out of a value lane, unchanged. */
	LaneReference;

	/** `IrHlScalarRef`: the address of a scalar, a load through it, and a store through it. */
	ScalarRefAddress;

	ScalarRefLoad;
	ScalarRefStore;

	/** An array push: inline while the array has room, the native otherwise. */
	ArrayPush;

	/** A byte read or write: inline in range, the native otherwise. */
	BytesGet;

	BytesSet;

	/** A value array element's field read: dropped when unused beside another read, inline when it can be. */
	ValueArrayRead;

	/** A value array element's check: dropped when a read of the element follows. */
	ValueArrayValidate;

	/** Any other function: called. */
	Plain;
}

/**
 * The lowering decisions both HashLink backends make the same way: the bytecode (`HlLower`) and the C of the AOT backend
 * (`HlcFunctionLower`). Each backend writes the decision in its own form; what is decided lives here once, so the two cannot
 * drift apart.
 */
@:nullSafety(Strict)
class HlLoweringDecisions {
	/** The error a call of a Dynamic value that is not a function throws. */
	public static inline final CALL_ERROR = "Cannot call a non-function value";

	/**
	 * A payload-free enum in tag storage is its constructor's index plus this, so that 0 is null (`NULL_ENUM_TAG`). Whether a
	 * value is in tag storage is decided by its IR type (`isEnumTag`): in a release build a tag nothing boxes has the plain
	 * I32 runtime type.
	 */
	public static inline final ENUM_TAG_BIAS = 1;

	public static inline final NULL_ENUM_TAG = 0;

	/** Whether values of IR type `type` are enum tags (`ENUM_TAG_BIAS`). */
	public static function isEnumTag(type:IrType):Bool
		return switch type {
			case EnumTag(_): true;
			default: false;
		};

	/**
	 * Whether `MakeEnum` row `row` makes a constructor without fields of an enum in boxed storage: it denotes one value, so it
	 * is made the first time it is evaluated and kept in a global, and every later evaluation is a global load.
	 */
	public static function isEnumConstant(body:IrBody, row:Int):Bool
		return body.operandCount(row) == 0 && !isEnumTag(body.valueType(body.output(row)));

	/**
	 * Whether an integer field read from native storage `storage` (`IrScalarStorage`) is narrower than its register and
	 * extended by its signedness: a byte or 16-bit field always.
	 */
	public static function extendsNarrowStorage(storage:Null<IrScalarStorage>):Bool
		return storage != null && storage.size < 4;

	/**
	 * The value row `row` dereferences and checks for null first, or no value. A native field, enum or array load cannot turn
	 * a hardware fault into a Haxe exception, so the check is explicit and the active handler works on every thread; nor can
	 * an array runtime native, which reads its array in C (`IrReceiverCheck.readsArray`).
	 */
	public static function receiverOf(body:IrBody, row:Int):IrValueId
		return switch body.opcode(row) {
			case IrOpcode.Call if (body.operandCount(row) > 0
				&& compiler.ir.names.IrReceiverCheck.readsArray(body.symbol(row).name)):
				body.operand(row, 0);
			case IrOpcode.FieldGet, IrOpcode.FieldSet, IrOpcode.MethodCall, IrOpcode.InstanceClosure, IrOpcode.ArrayGet,
				IrOpcode.ArraySet, IrOpcode.ArraySize, IrOpcode.IteratorNew, IrOpcode.IteratorHasNext,
				IrOpcode.IteratorNext,
				IrOpcode.EnumIndex, IrOpcode.EnumField:
				body.operand(row, 0);
			default: IrValueId.of(-1);
		};

	/**
	 * Whether row `row` boxes an array (`ToDyn`) only for the next row to cast it back to an array (`SafeCast`), as a coercion
	 * between array types does: HashLink arrays carry no element type, so the cast takes the array itself and the box is not
	 * made. `uses` counts the operands that read each value.
	 */
	public static function isArrayRecast(body:IrBody, row:Int, uses:Array<Int>):Bool {
		if (body.opcode(row) != IrOpcode.ToDyn)
			return false;
		var boxed = body.output(row), next = body.nextRow(row);
		return next >= 0 && body.opcode(next) == IrOpcode.SafeCast && (body.operand(next, 0):Int) == (boxed:Int)
			&& uses[boxed] == 1 && isArray(body.valueType(body.operand(row, 0)))
			&& isArray(body.valueType(body.output(next)));
	}

	static function isArray(type:IrType):Bool
		return switch type {
			case Array(_): true;
			default: false;
		};

	/** What a call of function `name` lowers to. */
	public static function classifyCall(name:String):HlCallKind
		return switch name {
			case compiler.ir.names.IrReceiverCheck.NAME: ReceiverCheck;
			case compiler.ir.names.IrReceiverCheck.STRING_LENGTH: StringLength;
			case compiler.ir.names.IrReferenceIdentity.NAME: ReferenceIdentity;
			case compiler.ir.analysis.IrExactTypeFacts.TEST: ExactTypeTest;
			case compiler.ir.passes.scalars.IrScalarWordBits.PACK,
				compiler.ir.passes.scalars.IrScalarWordBits.UNPACK: WordBits;
			case compiler.ir.passes.values.IrValueLaneReference.PACK,
				compiler.ir.passes.values.IrValueLaneReference.UNPACK:
				LaneReference;
			case compiler.ir.passes.scalars.IrHlScalarRef.ADDRESS: ScalarRefAddress;
			case compiler.ir.passes.scalars.IrHlScalarRef.LOAD: ScalarRefLoad;
			case compiler.ir.passes.scalars.IrHlScalarRef.STORE: ScalarRefStore;
			case "__array_push_i32", "__array_push_i64", "__array_push_f64", "__array_push_bool", "__array_push_bytes",
				"__array_push_ref": ArrayPush;
			case "__bytes_get": BytesGet;
			case "__bytes_try_set": BytesSet;
			case VALUE_ARRAY_VALIDATE: ValueArrayValidate;
			default: StringTools.startsWith(name, VALUE_ARRAY_READ) ? ValueArrayRead : Plain;
		};

	/** The runtime's value array natives: the check of an element, and its scalar reads, `VALUE_ARRAY_READ` and a width. */
	public static inline final VALUE_ARRAY_VALIDATE = "__value_array_validate";

	public static inline final VALUE_ARRAY_READ_I32 = "__value_array_read_i32";

	public static inline final VALUE_ARRAY_READ = "__value_array_read_";

	/**
	 * Whether a scalar read of the same element as the read at `position`, whose value is used, is beside it, with nothing
	 * but constants and reads of that element between: that read checks the element (in range, present) as this one would.
	 */
	public static function usedReadNearby(body:IrBody, row:Int, uses:Array<Int>):Bool {
		return usedReadBeside(body, row, uses, true) || usedReadBeside(body, row, uses, false);
	}

	/** `usedReadNearby` on one side of `row`: the rows before it, or those after it. */
	static function usedReadBeside(body:IrBody, row:Int, uses:Array<Int>, before:Bool):Bool {
		var array = body.operand(row, 0),
			index = body.operand(row, 1),
			at = before ? body.previousRow(row) : body.nextRow(row);
		while (at >= 0) {
			switch body.opcode(at) {
				case IrOpcode.ConstInt, IrOpcode.ConstBool:
				case IrOpcode.Call if (StringTools.startsWith(body.symbol(at).name, VALUE_ARRAY_READ)
					&& body.operandCount(at) >= 2 && (body.operand(at, 0):Int) == (array:Int)
					&& (body.operand(at, 1):Int) == (index:Int)):
					if (uses[body.output(at)] > 0)
						return true;
				default:
					break;
			}
			at = before ? body.previousRow(at) : body.nextRow(at);
		}
		return false;
	}

	/** The runtime's type of a value array header, which a forwarding header does not have (`value_arrays.c`). */
	public static inline final VALUE_ARRAY_HEADER_TYPE = "__value_array_header_type";

	public static inline final VALUE_ARRAY_FORWARD_TYPE = "__value_array_forward_type";

	/** Where a value array keeps its scalar stride in bits, and an array its size and data; `value_arrays.c` asserts them. */
	public static inline final VALUE_ARRAY_STRIDE_OFFSET = 88;

	public static inline final ARRAY_SIZE_OFFSET = 16;

	/** Where a value array keeps its validity lane (`value_arrays.c` asserts it). */
	public static inline final VALUE_ARRAY_VALIDITY_OFFSET = 104;
	public static inline final ARRAY_DATA_OFFSET = 24;

	/** The type word at the start of an array's storage. */
	public static inline final LANE_HEADER_BYTES = 8;

	/** How far back from a call its constant arguments are looked for; the IR emits them right before it. */
	public static inline final CONSTANT_LOOKBACK = 8;

	/** The Int or Bool constant (a Bool as 0 or 1) `value` is, when its definition is just before `index`; else -1. */
	static function constantBefore(body:IrBody, row:Int, value:IrValueId):Int {
		var position = body.previousRow(row), remaining = CONSTANT_LOOKBACK;
		while (position >= 0 && remaining > 0) {
			if ((body.output(position):Int) == (value:Int))
				switch body.opcode(position) {
					case IrOpcode.ConstInt:
						return body.aux(position);
					case IrOpcode.ConstBool:
						return body.aux(position) == 1 ? 1 : 0;
					default:
				}
			position = body.previousRow(position);
			remaining--;
		}
		return -1;
	}

	/** Whether a value array of `array`'s type is read inline (`hasValidity` tells how). */
	public static function readsInline(array:IrType):Bool
		return switch array {
			case Array(EnumTag(_)), Array(Enum(_)), Array(Nullable(Obj(_))), Array(Obj(_)): true;
			default: false;
		};

	/**
	 * Whether a value array of `array`'s type keeps a presence bit per element (`IrValueArrayLayout`): arrays of non-null
	 * structs do; enums (their null is tag zero) and nullable structs do not.
	 */
	public static function hasValidity(array:IrType):Bool
		return switch array {
			case Array(Obj(_)): true;
			default: false;
		};

	/**
	 * The slot `__value_array_read_i32` at `index` of `instructions` reads, as constants, when it is read inline
	 * (`lowerValueArrayRead`); null otherwise.
	 */
	public static function inlineValueArraySlot(body:IrBody, row:Int):Null<InlineValueSlot> {
		if (body.operandCount(row) != 5 || !readsInline(body.valueType(body.operand(row, 0))))
			return null;
		var offset = constantBefore(body, row, body.operand(row, 2)),
			width = constantBefore(body, row, body.operand(row, 3)),
			signed = constantBefore(body, row, body.operand(row, 4));
		return offset >= 0 && offset % 8 == 0 && signed >= 0 && (width == 8 || width == 16 || width == 32)
			? {offset: offset, width: width, signed: signed == 1} : null;
	}

	/**
	 * Whether the first instruction from `start` on that is not a constant reads a scalar of the element `validate` checks.
	 * The HashLink runtime's scalar reads validate their element as `__value_array_validate` does, with the same errors, so
	 * a validation right before one adds nothing: a payload-free enum element is read as exactly that pair.
	 */
	public static function scalarReadFollows(body:IrBody, row:Int):Bool {
		if (body.operandCount(row) != 2)
			return false;
		var array = body.operand(row, 0), index = body.operand(row, 1), position = body.nextRow(row);
		while (position >= 0) {
			switch body.opcode(position) {
				case IrOpcode.ConstInt, IrOpcode.ConstBool:
				case IrOpcode.Call:
					return StringTools.startsWith(body.symbol(position).name, "__value_array_read_")
						&& body.operandCount(position) >= 2 && (body.operand(position, 0):Int) == (array:Int)
						&& (body.operand(position, 1):Int) == (index:Int);
				default:
					return false;
			}
			position = body.nextRow(position);
		}
		return false;
	}

	/** The native an iterator's `next` calls for elements of type `element`, and what it returns. */
	public static function iteratorNextNative(element:IrType):{name:String, result:IrType} return switch element {
		case F64: {name: "__iterator_next_f64", result: IrType.F64};
		case I32: {name: "__iterator_next_i32", result: IrType.I32};
		default: {name: "__iterator_next", result: IrType.Dyn};
	};

	/**
	 * How a call of ordinary C function `native` with `argumentCount` arguments goes through the runtime's dispatch: the invoke
	 * native, the strings (library, symbol, signature, then for a pointer result its ownership, release and length) and the
	 * nullable flag, which go before the boxed arguments with the flag last, the type the invoker returns, and whether
	 * that is cast to the result. Both HashLink backends call it so.
	 */
	public static function cNativeInvocation(native:IrCNative, argumentCount:Int):{
		invoker:String,
		strings:Array<String>,
		nullable:Null<Bool>,
		result:IrType,
		castsResult:Bool,
		isVoid:Bool
	} {
		var functionName = native.name;
		for (type in native.arguments)
			if (unsupportedCDispatchArgument(type))
				throw new InternalError('Ordinary C function "$functionName" uses an unsupported executable argument type $type');
		var isVoid = switch (native.result) {
			case Void: true;
			default: false;
		};
		if (!isVoid && unsupportedCDispatchResult(native.result))
			throw new InternalError('Ordinary C function "$functionName" uses an unsupported executable result type ${native.result}');
		var strings = [native.library, native.symbol, native.signature];
		var pointerResult = isNativePointer(native.result),
			bytesResult = isManagedPointerBytes(native),
			aggregateResult = isAggregateResult(native),
			utf8Result = isUtf8Result(native);
		var nullable:Null<Bool> = null;
		if (pointerResult || bytesResult || utf8Result) {
			strings.push(native.pointerOwnership);
			strings.push(native.pointerRelease == null ? "" : native.pointerRelease);
			// A bytes result is one with a length (`isManagedPointerBytes`).
			var length = native.pointerLength;
			if (bytesResult && length != null)
				strings.push(length);
			nullable = native.pointerNullable;
		}
		return {
			invoker: pointerResult ? '__c_native_pointer_invoke_${argumentCount}' : bytesResult
				? '__c_native_bytes_invoke_${argumentCount}' : aggregateResult
				? '__c_native_aggregate_invoke_${argumentCount}' : utf8Result
				? '__c_native_utf8_invoke_${argumentCount}' : '__c_native_invoke_${argumentCount}',
			strings: strings,
			nullable: nullable,
			result: pointerResult ? IrType.Abstract("native_pointer") : (bytesResult || aggregateResult)
				? IrType.ManagedBytes : utf8Result ? IrType.Bytes : IrType.Dyn,
			castsResult: !(pointerResult || bytesResult || aggregateResult || utf8Result),
			isVoid: isVoid
		};
	}

	static function unsupportedCDispatchArgument(type:IrType):Bool
		return switch type {
			case I32, I64, IrType.Bool, F32, F64, IrType.Bytes, IrType.RawPtr, IrType.ManagedBytes,
				IrType.Abstract("realtime_bytes"),
				IrType.Abstract("native_pointer"), IrType.Abstract("native_callback"): false;
			default: true;
		};

	static function unsupportedCDispatchResult(type:IrType):Bool
		return switch type {
			case I32, I64, IrType.Bool, F32, F64, IrType.Bytes, IrType.RawPtr, IrType.ManagedBytes,
				IrType.Abstract("native_pointer"),
				IrType.Abstract("realtime_bytes"): false;
			default: true;
		};

	public static function isNativePointer(type:IrType):Bool
		return switch type {
			case IrType.Abstract("native_pointer"): true;
			case _: false;
		};

	public static function isManagedPointerBytes(native:IrCNative):Bool
		return native.pointerLength != null && switch native.result {
			case IrType.ManagedBytes, IrType.Abstract("realtime_bytes"): true;
			case _: false;
		};

	public static function isAggregateResult(native:IrCNative):Bool
		return native.pointerLength == null && switch (native.result) {
			case IrType.ManagedBytes, IrType.Abstract("realtime_bytes"): true;
			case _: false;
		};

	public static function isUtf8Result(native:IrCNative):Bool {
		var separator = native.signature.indexOf(">");
		if (separator < 0)
			return false;
		var result = native.signature.substr(separator + 1);
		return StringTools.startsWith(result, "13") || StringTools.startsWith(result, "14");
	}
}

/** A value array scalar slot read inline: its bit offset in the element, its width in bits and whether it is signed. */
typedef InlineValueSlot = {
	final offset:Int;
	final width:Int;
	final signed:Bool;
}
