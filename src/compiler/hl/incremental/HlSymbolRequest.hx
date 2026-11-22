package compiler.hl.incremental;

import compiler.ir.model.Ir.IrScalarStorage;
import compiler.ir.model.Ir.IrType;

/**
 * One question lowering put to the symbol tables or the function layout while it lowered a function, with the answer it got. The
 * requests of a function, in order, are everything its code leans on outside itself: replaying them against other tables gives the
 * indices the same function needs there (`HlRemap`), and the tables come out as lowering the functions in that order would make them.
 *
 * Constants, types, globals and functions are remapped. A field, a method slot or an enum constructor is a position inside a
 * type the IR names: it is not remapped, and a replay that finds a different one means the function must be lowered again. A
 * lowered function keeps its requests as numbers (`HlRequestKeys`).
 */
enum HlSymbolRequest {
	ConstInt(value:Int, index:Int);
	ConstFloat(value:Float, index:Int);
	ConstString(value:String, index:Int);

	/** `HlLower.internType`: a function type goes through `internFunction`, any other through `internType`. */
	TypeOf(type:IrType, index:Int);

	/** A reference to a type, for pointer-size-aware header access. */
	RefTo(type:IrType, index:Int);

	/** An object type laid out like a runtime header (`HlSymbolTable.internRuntimeHeader`). */
	RuntimeHeader(kind:HlRuntimeHeader, index:Int);

	/** The narrow storage type of a native field; null when the field has none. */
	NativeStorage(type:IrType, layout:IrScalarStorage, index:Null<Int>);

	/** A global made on first use (`internGlobal`). */
	GlobalSlot(name:String, type:IrType, index:Int);

	/** A global that must exist already: a static field. */
	GlobalByName(name:String, index:Int);

	StringLiteral(value:String, index:Int);
	EnumValue(enumName:String, constructor:Int, index:Int);

	/** A function, by name, in the function layout of the build. */
	FunctionRef(name:String, index:Int);

	/** The field `name` declared by `owner`, as HashLink indexes it. */
	FieldSlot(owner:String, name:String, index:Null<Int>);

	MethodSlot(typeName:String, name:String, index:Int);
	InterfaceSlot(interfaceName:String, name:String, index:Int);

	/** Whether the object type has a prototype slot for the method: 0 no slot table, 1 a slot, 2 a table without that method. */
	MethodSlotKnown(typeName:String, name:String, answer:Int);
}

/**
 * A runtime object whose header the HashLink lowering reads in place: its fields, after the header word every object starts with, are
 * where an object type with these fields keeps them, on 32- and 64-bit alike.
 */
enum abstract HlRuntimeHeader(Int) {
	/** `realtime_bytes`: the finalizer word, then `data` (field 0) and `length` (field 1). */
	var BytesHeader = 0;

	/** `varray`: the type word, the element type (field 0), then `size` (field 1) and `capacity` (field 2). */
	var ArrayHeader = 1;
}

/** How a function's indices change between two builds, by table (`HlRequestKeys.INTS` to `FUNCTIONS`). */
class HlRemap {
	public final ints:Map<Int, Int> = [];
	public final floats:Map<Int, Int> = [];
	public final strings:Map<Int, Int> = [];
	public final types:Map<Int, Int> = [];
	public final globals:Map<Int, Int> = [];
	public final functions:Map<Int, Int> = [];

	public function new() {}

	/** Notes that index `from` of `table` is `to` in this build. */
	public function note(table:Int, from:Int, to:Int):Void (switch table {
		case HlRequestKeys.INTS: ints;
		case HlRequestKeys.FLOATS: floats;
		case HlRequestKeys.STRINGS: strings;
		case HlRequestKeys.TYPES: types;
		case HlRequestKeys.GLOBALS: globals;
		case HlRequestKeys.FUNCTIONS: functions;
		default: throw new compiler.core.InternalError('HashLink link: table $table has no indices');
	}).set(from, to);

	/** The index of `type`, the way lowering asks for it. */
	public static function typeIndex(symbols:HlSymbolTable, type:IrType):Int
		return switch type {
			case Function(arguments, result): symbols.internFunction(arguments, result);
			default: symbols.internType(type);
		};

	public static function methodSlotAnswer(symbols:HlSymbolTable, typeName:String, name:String):Int {
		var slots = symbols.objectMethodSlots(typeName);
		return slots == null ? 0 : slots.exists(name) ? 1 : 2;
	}
}
