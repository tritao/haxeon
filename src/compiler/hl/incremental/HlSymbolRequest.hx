package compiler.hl.incremental;

import compiler.ir.Ir.IrScalarStorage;
import compiler.ir.Ir.IrType;

/**
 * One question lowering put to the symbol tables or the function layout while it lowered a function, with the answer it got. The
 * requests of a function, in order, are everything its code leans on outside itself: replaying them against other tables gives the
 * indices the same function needs there (`HlRemap`), and the tables come out as lowering the functions in that order would make them.
 *
 * Constants, types, globals and functions are remapped. A field, a method slot or an enum constructor is a position inside a
 * type the IR names: it is not remapped, and a replay that finds a different one means the function must be lowered again.
 */
enum HlSymbolRequest {
	ConstInt(value:Int, index:Int);
	ConstFloat(value:Float, index:Int);
	ConstString(value:String, index:Int);

	/** `HlLower.internType`: a function type goes through `internFunction`, any other through `internType`. */
	TypeOf(type:IrType, index:Int);

	/** A reference to a type, for pointer-size-aware header access. */
	RefTo(type:IrType, index:Int);

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

/** How a function's indices change between two builds, filled by replaying its requests. */
class HlRemap {
	public final ints:Map<Int, Int> = [];
	public final floats:Map<Int, Int> = [];
	public final strings:Map<Int, Int> = [];
	public final types:Map<Int, Int> = [];
	public final globals:Map<Int, Int> = [];
	public final functions:Map<Int, Int> = [];

	/** Whether every index maps to itself, so the function can be kept as it is. */
	public var identity = true;

	public function new() {}

	function note(map:Map<Int, Int>, from:Int, to:Int):Void {
		map.set(from, to);
		if (from != to)
			identity = false;
	}

	/**
	 * Asks `symbols` and `functions` what `request` asked when the function was lowered. Null when the answer maps (or equals);
	 * a description when a position the function bakes in has moved.
	 */
	public function replay(request:HlSymbolRequest, symbols:HlSymbolTable, functions:Map<String, Int>):Null<String> {
		switch request {
			case ConstInt(value, index):
				note(ints, index, symbols.internInt(value));
			case ConstFloat(value, index):
				note(floats, index, symbols.internFloat(value));
			case ConstString(value, index):
				note(strings, index, symbols.internString(value));
			case TypeOf(type, index):
				note(types, index, typeIndex(symbols, type));
			case RefTo(type, index):
				note(types, index, symbols.internReference(type));
			case NativeStorage(type, layout, index):
				var next = symbols.internNativeFieldStorageType(type, layout);
				if (index != null && next != null)
					note(types, index, next);
				else if (index != null || next != null)
					return "native storage of " + Std.string(type);
			case GlobalSlot(name, type, index):
				note(globals, index, symbols.internGlobal(name, type));
			case GlobalByName(name, index):
				note(globals, index, symbols.requireGlobalIndex(name));
			case StringLiteral(value, index):
				note(globals, index, symbols.internStringConstant(value));
			case EnumValue(enumName, constructor, index):
				note(globals, index, symbols.internEnumConstant(enumName, constructor));
			case FunctionRef(name, index):
				var next = functions.get(name);
				if (next == null)
					return 'function $name is gone';
				note(this.functions, index, next);
			case FieldSlot(owner, name, index):
				if (symbols.objectFieldIndex(owner, name) != index)
					return 'field $owner.$name moved';
			case MethodSlot(typeName, name, index):
				if (symbols.requireObjectMethodIndex(typeName, name) != index)
					return 'method $typeName.$name moved';
			case InterfaceSlot(interfaceName, name, index):
				if (symbols.requireInterfaceMethodIndex(interfaceName, name) != index)
					return 'interface method $interfaceName.$name moved';
			case MethodSlotKnown(typeName, name, answer):
				if (methodSlotAnswer(symbols, typeName, name) != answer)
					return 'method slot of $typeName.$name changed';
		}
		return null;
	}

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
