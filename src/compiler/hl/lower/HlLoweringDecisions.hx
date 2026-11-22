package compiler.hl.lower;

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
	 * a hardware fault into a Haxe exception, so the check is explicit and the active handler works on every thread.
	 */
	public static function receiverOf(body:IrBody, row:Int):IrValueId
		return switch body.opcode(row) {
			case IrOpcode.FieldGet, IrOpcode.FieldSet, IrOpcode.MethodCall, IrOpcode.InstanceClosure, IrOpcode.ArrayGet,
				IrOpcode.ArraySet, IrOpcode.ArraySize, IrOpcode.IteratorNew, IrOpcode.IteratorHasNext,
				IrOpcode.IteratorNext,
				IrOpcode.EnumIndex, IrOpcode.EnumField:
				body.operand(row, 0);
			default: IrValueId.of(-1);
		};

	/**
	 * Whether a row of opcode `opcode` leaves every proven array bound intact: it runs no code and shrinks no array. Anything
	 * else, including every call, forgets them. Array writes only ever grow an array, so they keep them.
	 */
	public static function keepsArrayBounds(opcode:IrOpcode):Bool
		return switch opcode {
			case IrOpcode.ConstVoid, IrOpcode.ConstInt, IrOpcode.ConstFloat, IrOpcode.ConstString, IrOpcode.ConstBool,
				IrOpcode.ConstNull, IrOpcode.TypeValue, IrOpcode.ToDyn, IrOpcode.IntToFloat, IrOpcode.IntToInt64,
				IrOpcode.FloatToInt, IrOpcode.FloatToFloat, IrOpcode.Add, IrOpcode.Sub, IrOpcode.Mul, IrOpcode.BitAnd,
				IrOpcode.BitXor, IrOpcode.BitOr, IrOpcode.ShiftLeft, IrOpcode.ShiftRight, IrOpcode.UnsignedShiftRight,
				IrOpcode.Less, IrOpcode.LessEqual, IrOpcode.Equal, IrOpcode.FieldGet, IrOpcode.ArrayGet,
				IrOpcode.ArraySet, IrOpcode.ArraySize, IrOpcode.Phi: true;
			default: false;
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
			case HlLower.VALUE_ARRAY_VALIDATE: ValueArrayValidate;
			default: StringTools.startsWith(name, HlLower.VALUE_ARRAY_READ) ? ValueArrayRead : Plain;
		};
}
