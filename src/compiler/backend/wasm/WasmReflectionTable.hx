package compiler.backend.wasm;

import compiler.ir.Ir.IrProgram;

private typedef ReflectionRow = {final typeId:Int; final functions:Array<Null<String>>;}

/**
 * The table both Wasm backends use to dispatch field reflection over object layouts (`__reflect_object_*`): one row per
 * class, sorted by the class id in the object header, holding a function-table slot for each operation. The program
 * carries one function per layout; looking a value's row up is a binary search whose cost does not depend on how many
 * classes there are. Rows are little-endian 32-bit words, so linear memory and a Wasm GC array read the same bytes.
 */
class WasmReflectionTable {
	public static final OPERATIONS = [
		"__reflect_object_field",
		"__reflect_object_set_field",
		"__reflect_object_field_count",
		"__reflect_object_field_name",
		"__reflect_object_delete_field"
	];

	/** Class id, then one slot for each of OPERATIONS. */
	public static inline final ROW_SIZE = 24;

	public static inline final ROW_WORDS = 6;

	public static function operationIndex(symbol:String):Int
		return OPERATIONS.indexOf(symbol);

	public static function declares(program:IrProgram):Bool {
		for (native in program.natives)
			if (operationIndex(native.symbol) >= 0)
				return true;
		return false;
	}

	/**
	 * A row for every class that has a layout of its own or inherits one, naming the per-layout functions of the nearest
	 * layout up its base chain, so an instance of a class that is not itself reflected still reflects as its base does.
	 */
	static function rows(program:IrProgram):Array<ReflectionRow> {
		var nativeNames:Array<Null<String>> = [for (_ in OPERATIONS) null],
			functionNames:Map<String, Bool> = [for (fn in program.functions) fn.name => true],
			objects = [for (object in program.objects) object.name => object];
		for (native in program.natives) {
			var index = operationIndex(native.symbol);
			if (index >= 0)
				nativeNames[index] = native.name;
		}
		var result:Array<ReflectionRow> = [];
		for (object in program.objects) {
			if (object.isValue)
				continue;
			var functions:Array<Null<String>> = [for (_ in OPERATIONS) null], owner:Null<String> = object.name, found = false;
			while (owner != null && !found) {
				for (index in 0...OPERATIONS.length) {
					var native = nativeNames[index];
					if (native != null && functionNames.exists('$native.$owner')) {
						functions[index] = '$native.$owner';
						found = true;
					}
				}
				if (!found) {
					var base = objects.get(owner);
					owner = base == null ? null : base.base;
				}
			}
			if (found)
				result.push({typeId: WasmModuleSupport.typeId(Obj(object.name)), functions: functions});
		}
		result.sort((left, right) -> left.typeId < right.typeId ? -1 : left.typeId > right.typeId ? 1 : 0);
		return result;
	}

	/** Bytes the table needs; the contents are filled in once function-table slots are known (finalize). */
	public static function tableSize(program:IrProgram):Int
		return declares(program) ? rows(program).length * ROW_SIZE : 0;

	/** Writes the rows once every function has a slot in the table; a function the program never reaches gets -1. */
	public static function fill(bytes:haxe.io.Bytes, program:IrProgram, slots:Map<String, Int>):Void {
		var all = rows(program);
		for (index in 0...all.length) {
			var offset = index * ROW_SIZE;
			bytes.setInt32(offset, all[index].typeId);
			for (column in 0...OPERATIONS.length) {
				var name = all[index].functions[column],
					slot = name == null ? null : slots.get(name);
				bytes.setInt32(offset + 4 + 4 * column, slot == null ? -1 : slot);
			}
		}
	}
}
