package compiler.backend.wasm;

import compiler.ir.Ir;
import compiler.ir.IrOperands;
import compiler.ir.IrTypeIdentity;

/** Module-owned, collision-free identifiers for runtime types. */
class WasmTypeIdPlan {
	final ids:Map<String, Int> = [];
	final hashes:Map<Int, Int> = [];

	public function new(types:Array<IrType>) {
		var keys:Map<String, IrType> = [];
		function add(type:IrType):Void {
			var key = Std.string(type);
			if (keys.exists(key)) return;
			keys.set(key, type);
			switch type {
				case Nullable(inner), Array(inner), Iterator(inner): add(inner);
				case Function(arguments, result): for (argument in arguments) add(argument); add(result);
				default:
			}
		}
		for (type in types) add(type);
		var names = [for (name in keys.keys()) name]; names.sort(Reflect.compare);
		var groups:Map<Int, Array<String>> = [], used:Map<Int, Bool> = [0 => true, WasmLayout.CLOSURE_TYPE_ID => true];
		for (name in names) {
			var hash = IrTypeIdentity.id(keys.get(name)), group = groups.get(hash);
			if (group == null) groups.set(hash, group = []);
			group.push(name);
		}
		// Reserve every unmodified hash before resolving collisions, so resolving
		// one group never displaces an otherwise unrelated type.
		for (hash in groups.keys()) if (!used.exists(hash)) used.set(hash, true);
		var nextFree = 1;
		for (name in names) {
			var hash = IrTypeIdentity.id(keys.get(name)), group = groups.get(hash), id = hash;
			if (hash == 0 || hash == WasmLayout.CLOSURE_TYPE_ID || group[0] != name) {
				// One shared cursor bounds all collision probing together, even
				// when many names have the same initial hash.
				while (used.exists(nextFree)) nextFree++;
				id = nextFree++;
				used.set(id, true);
			}
			ids.set(name, id);
			hashes.set(id, hash);
		}
	}

	public function id(type:IrType):Int {
		var key = Std.string(type), result = ids.get(key);
		if (result == null) throw 'Wasm runtime type was not planned: $key';
		return result;
	}

	/** Identifiers that need translation back to their stable dispatch hash. */
	public function remapped():Array<{id:Int, hash:Int}> {
		var result = [for (id in hashes.keys()) if (id != hashes.get(id)) {id:id, hash:hashes.get(id)}];
		result.sort((a, b) -> a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
		return result;
	}

	/** An existing module can keep its objects only while shared type IDs remain unchanged. */
	public function compatibleWith(previous:WasmTypeIdPlan):Bool {
		for (key in previous.ids.keys()) if (!ids.exists(key) || previous.ids.get(key) != ids.get(key)) return false;
		return true;
	}

	public static function forProgram(program:IrProgram):WasmTypeIdPlan {
		var types:Array<IrType> = [Void, I32, I64, Bool, F32, F64, Bytes, RawPtr, ManagedBytes, Dyn, TypeRef, Array(Dyn),
			Abstract("native_callback"), Abstract("native_pointer"), Abstract("realtime_bytes"), Abstract("realtime_bytes_input"),
			Abstract("realtime_bytes_output"), Abstract("realtime_iterator")];
		for (object in program.objects) {
			types.push(Obj(object.name));
			for (field in object.fields) types.push(field.type);
		}
		for (item in program.enums) { types.push(Enum(item.name)); for (variant in item.cases) for (param in variant.params) types.push(param); }
		for (item in program.interfaces) { types.push(Virtual(item.name)); for (method in item.methods) {
			for (argument in method.arguments) types.push(argument); types.push(method.result);
		} }
		for (field in program.staticFields) types.push(field.type);
		for (native in program.natives) { for (argument in native.arguments) types.push(argument); types.push(native.result); }
		for (native in program.cNatives) { for (argument in native.arguments) types.push(argument); types.push(native.result); }
		for (fn in program.functions) {
			for (argument in fn.arguments) types.push(argument.type);
			types.push(fn.result);
			for (block in fn.blocks) for (located in block.instructions) {
				var instruction = located.value, output = IrOperands.output(instruction);
				if (output != null) types.push(output.type);
				for (input in IrOperands.inputs(instruction)) types.push(input.type);
				switch instruction { case TypeValue(_, type): types.push(type); default: }
			}
		}
		return new WasmTypeIdPlan(types);
	}
}
