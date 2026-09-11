package compiler.backend.wasm;

import compiler.backend.Backend;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.IrVerifier;
import compiler.ir.IrFunction;
import haxe.io.Bytes as HaxeBytes;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmStructurer.WasmLoopInfo;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;

private typedef WasmClosureTypes = {
	final staticType:Int;
	var instanceType:Null<Int>;
}

/** First self-hosted Wasm backend: scalar lowering with explicit CFG fallback. */
class WasmBackend implements Backend {
	public function new() {}

	public function compile(program:IrProgram, options:BackendOptions):BackendResult {
		var target = WasmTarget.forBackend(options.target, options.debugNames);
		if (target.referenceModel != Linear32)
			throw 'Wasm backend target ${options.target} is not implemented yet';
		IrVerifier.verify(program);
		var module = new WasmModule(target.debugNames ? "haxeon" : null);
		var layout = new WasmLayout(program);
		var strings:Map<String, Int> = [],
			nextData = WasmLayout.STRING_DATA_OFFSET;
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case ConstString(_, value):
							if (!strings.exists(value)) {
								var bytes = stringBytes(value);
								var offset = nextData;
								module.data.push({offset: offset, bytes: bytes});
								strings.set(value, offset);
								nextData = align(offset + bytes.length, 8);
							}
						default:
					}
		module.memoryMin = 1;
		module.exportMemory = true;
		var heapStart = Std.int(Math.max(1024, nextData));
		module.globals.push({type: I32, mutable: true, init: [I32Const(heapStart)]});
		var globals:Map<String, Int> = [];
		for (field in program.staticFields) {
			globals.set(field.name, module.globals.length);
			module.globals.push({type: requireValueType(field.type), mutable: true, init: zeroValue(field.type)});
		}
		var allocator = addAllocator(module);
		var preferredEntry = hasFunction(program, "main") ? "main" : hasFunction(program, "Main.main") ? "Main.main" : program.entryPoint;
		var reachable = reachableFunctions(program, preferredEntry);
		if (preferredEntry != program.entryPoint && hasFunction(program, "__init"))
			reachable.set("__init", true);
		var functions:Map<String, Int> = [];
		functions.set("__haxeon_alloc", allocator);
		addRuntimeFunctions(module, functions, program, allocator);
		for (native in program.natives) {
			var stride = arrayStrideForNative(native.name);
			if (stride != null)
				functions.set(native.name, addArrayAllocator(module, native.name, stride, allocator));
		}
		var methods:Map<String, String> = [];
		for (object in program.objects)
			for (method in object.methods)
				methods.set(object.name + "." + method.name, method.functionName);
		var emitted:Array<IrFunction> = [];
		for (fn in program.functions) {
			if (!reachable.exists(fn.name))
				continue;
			if (fn.name == "__entry" && preferredEntry != "__entry")
				continue;
			var type:WasmFunctionType = {parameters: [for (argument in fn.arguments) requireValueType(argument.type)], results: resultTypes(fn.result)};
			functions.set(fn.name, module.addFunction(new WasmFunction(fn.name, type)));
			emitted.push(fn);
		}
		var closureTypes = collectClosureTypes(module, program),
			tableSlots = buildTableSlots(module, functions),
			exceptionTag = hasExceptions(program) ? module.typeIndex({
				parameters: [I32],
				results: []
			}) : null;
		module.exceptionTagType = exceptionTag;
		module.customSections.push({name: "haxeon.gc.roots", bytes: WasmGcRoots.encode(program)});
		module.customSections.push({name: "haxeon.patch", bytes: WasmPatch.manifest(program)});
		for (index in 0...emitted.length) {
			var fn = emitted[index];
			var functionIndex = functions.get(fn.name);
			module.functions[functionIndex] = WasmFunctionLower.lower(fn, functions, module.functions[functionIndex].type, layout, allocator, globals,
				strings, methods, closureTypes, tableSlots, exceptionTag);
		}
		var entry = functions.get(preferredEntry);
		if (entry == null)
			throw 'Wasm entry point $preferredEntry was not emitted';
		if (preferredEntry != program.entryPoint && hasFunction(program, "__init")) {
			var entryType:WasmFunctionType = {parameters: [], results: resultTypes(programFunction(program, preferredEntry).result)};
			var wrapperBody:Array<WasmInstruction> = [Call(functions.get("__init")), Call(entry)];
			if (entryType.results.length == 0)
				wrapperBody.push(Return);
			else
				wrapperBody.push(Return);
			entry = module.addFunction(new WasmFunction("__haxeon_entry", entryType, [], wrapperBody));
		}
		module.exports.push({name: "main", functionIndex: entry});
		return {target: options.target, bytes: WasmEncoder.encode(module)};
	}

	static function addRuntimeFunctions(module:WasmModule, functions:Map<String, Int>, program:IrProgram, allocator:Int):Void {
		for (native in program.natives)
			switch native.name {
				case "__string_length":
					functions.set(native.name,
						module.addFunction(new WasmFunction(native.name, {parameters: [I32], results: [I32]}, [],
							[LocalGet(0), I32Load(WasmLayout.STRING_LENGTH_OFFSET), Return])));
				case "__string_char_code_at":
					functions.set(native.name, addStringCharCodeAt(module, native.name));
				case "__string_concat":
					functions.set(native.name, addStringConcat(module, native.name, allocator));
				case "__string_equal":
					functions.set(native.name, addStringEqual(module, native.name));
				case "__std_int_f64":
					functions.set(native.name,
						module.addFunction(new WasmFunction(native.name, {parameters: [F64], results: [I32]}, [], [LocalGet(0), I32TruncF64S, Return])));
				case "__std_string":
					functions.set(native.name,
						module.addFunction(new WasmFunction(native.name, {parameters: [I32], results: [I32]}, [], [LocalGet(0), Return])));
				case "__dynamic_equal":
					// Emitted after the native scan so the string helper has an index.
				case "__std_is_of_type", "__exception_matches":
					functions.set(native.name, addTypeTest(module, native.name, program));
				case "__array_copy_i32", "__array_copy_bool", "__array_copy_ref", "__array_copy_bytes":
					functions.set(native.name, addArrayCopy(module, native.name, 4, allocator));
				case "__array_copy_f64":
					functions.set(native.name, addArrayCopy(module, native.name, 8, allocator));
				case "__array_index_of_i32", "__array_index_of_bool", "__array_index_of_ref":
					functions.set(native.name, addArrayIndexOf(module, native.name, 4, I32, null));
				case "__array_index_of_bytes":
					var stringEqual = functions.get("__string_equal");
					if (stringEqual == null) {
						stringEqual = addStringEqual(module, "__string_equal");
						functions.set("__string_equal", stringEqual);
					}
					functions.set(native.name, addArrayIndexOf(module, native.name, 4, I32, stringEqual));
				case "__array_index_of_f64":
					functions.set(native.name, addArrayIndexOf(module, native.name, 8, F64, null));
				case "__array_slice_i32", "__array_slice_bool", "__array_slice_ref", "__array_slice_bytes":
					functions.set(native.name, addArraySlice(module, native.name, 4, allocator));
				case "__array_slice_f64":
					functions.set(native.name, addArraySlice(module, native.name, 8, allocator));
				case "__array_join_bytes":
					var stringConcat = functions.get("__string_concat");
					if (stringConcat == null) {
						stringConcat = addStringConcat(module, "__string_concat", allocator);
						functions.set("__string_concat", stringConcat);
					}
					functions.set(native.name, addArrayJoinBytes(module, native.name, allocator, stringConcat));
				case "__array_concat_i32", "__array_concat_bool", "__array_concat_ref", "__array_concat_bytes":
					functions.set(native.name, addArrayConcat(module, native.name, 4, allocator));
				case "__array_concat_f64":
					functions.set(native.name, addArrayConcat(module, native.name, 8, allocator));
				case "__array_push_i32", "__array_push_bool", "__array_push_ref", "__array_push_bytes":
					functions.set(native.name, addArrayPush(module, native.name, 4, I32, allocator));
				case "__array_push_f64":
					functions.set(native.name, addArrayPush(module, native.name, 8, F64, allocator));
				case "__array_pop_i32", "__array_pop_bool", "__array_pop_ref", "__array_pop_bytes":
					functions.set(native.name, addArrayPop(module, native.name, 4, I32));
				case "__array_pop_f64":
					functions.set(native.name, addArrayPop(module, native.name, 8, F64));
				case "__array_unshift_i32", "__array_unshift_bool", "__array_unshift_ref", "__array_unshift_bytes":
					functions.set(native.name, addArrayUnshift(module, native.name, 4, I32, allocator));
				case "__array_unshift_f64":
					functions.set(native.name, addArrayUnshift(module, native.name, 8, F64, allocator));
				case "__array_insert_i32", "__array_insert_bool", "__array_insert_ref", "__array_insert_bytes":
					functions.set(native.name, addArrayInsert(module, native.name, 4, I32, allocator));
				case "__array_insert_f64":
					functions.set(native.name, addArrayInsert(module, native.name, 8, F64, allocator));
				case "__array_shift_i32", "__array_shift_bool", "__array_shift_ref", "__array_shift_bytes":
					functions.set(native.name, addArrayShift(module, native.name, 4, I32));
				case "__array_shift_f64":
					functions.set(native.name, addArrayShift(module, native.name, 8, F64));
				case "__array_resize_i32", "__array_resize_bool", "__array_resize_ref", "__array_resize_bytes":
					functions.set(native.name, addArrayResize(module, native.name, 4, I32, allocator));
				case "__array_resize_f64":
					functions.set(native.name, addArrayResize(module, native.name, 8, F64, allocator));
				case "__array_remove_i32", "__array_remove_bool", "__array_remove_ref":
					functions.set(native.name, addArrayRemove(module, native.name, 4, I32, null));
				case "__array_remove_bytes":
					var stringEqual = functions.get("__string_equal");
					if (stringEqual == null) {
						stringEqual = addStringEqual(module, "__string_equal");
						functions.set("__string_equal", stringEqual);
					}
					functions.set(native.name, addArrayRemove(module, native.name, 4, I32, stringEqual));
				case "__array_remove_f64":
					functions.set(native.name, addArrayRemove(module, native.name, 8, F64, null));
				case "__array_reverse_i32", "__array_reverse_bool", "__array_reverse_ref", "__array_reverse_bytes":
					functions.set(native.name, addArrayReverse(module, native.name, 4, I32));
				case "__array_reverse_f64":
					functions.set(native.name, addArrayReverse(module, native.name, 8, F64));
				case "__array_splice_i32", "__array_splice_bool", "__array_splice_ref", "__array_splice_bytes":
					functions.set(native.name, addArraySplice(module, native.name, 4, allocator));
				case "__array_splice_f64":
					functions.set(native.name, addArraySplice(module, native.name, 8, allocator));
				default:
			}
		for (native in program.natives)
			if (native.name == "__dynamic_equal") {
				var stringEqual = functions.get("__string_equal");
				if (stringEqual == null) {
					stringEqual = addStringEqual(module, "__string_equal");
					functions.set("__string_equal", stringEqual);
				}
				functions.set(native.name, addDynamicEqual(module, native.name, stringEqual));
			}
	}

	static function collectClosureTypes(module:WasmModule, program:IrProgram):Map<String, WasmClosureTypes> {
		var result:Map<String, WasmClosureTypes> = [];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case CallClosure(_, closure, _):
							switch closure.type {
								case Function(arguments, resultType):
									var type:WasmFunctionType = {
										parameters: [for (argument in arguments) requireValueType(argument)],
										results: resultTypes(resultType)
									};
									var key = Std.string(closure.type);
									if (!result.exists(key)) result.set(key, {staticType: module.typeIndex(type), instanceType: null});
								default:
							}
						case InstanceClosure(output, name, _):
							var target:Null<IrFunction> = null;
							for (candidate in program.functions)
								if (candidate.name == name)
									target = candidate;
							if (target == null || target.arguments.length == 0)
								throw 'Wasm instance closure target "$name" has no receiver';
							var closureArguments = switch output.type {
								case Function(arguments, _): arguments;
								default: throw 'Wasm instance closure has an invalid function type';
							};
							var resultType = switch output.type {
								case Function(_, result): result;
								default: Void;
							};
							var staticType = module.typeIndex({
								parameters: [for (argument in closureArguments) requireValueType(argument)],
								results: resultTypes(resultType)
							}), instanceType = module.typeIndex({
								parameters: [requireValueType(target.arguments[0].type)].concat([for (argument in closureArguments) requireValueType(argument)]),
								results: resultTypes(resultType)
							});
							var key = Std.string(output.type),
								existing = result.get(key);
							if (existing == null)
								result.set(key, {staticType: staticType, instanceType: instanceType});
							else
								existing.instanceType = instanceType;
						default:
					}
		return result;
	}

	static function buildTableSlots(module:WasmModule, functions:Map<String, Int>):Map<String, Int> {
		var names = [for (fn in module.functions) fn.name];
		names.sort(Reflect.compare);
		var slots:Map<String, Int> = [];
		for (index in 0...names.length) {
			slots.set(names[index], index);
			module.tableElements.push(functions.get(names[index]));
		}
		module.tableMin = names.length;
		return slots;
	}

	static function addTypeTest(module:WasmModule, name:String, program:IrProgram):Int {
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(0),
			LocalSet(2),
			Else,
			LocalGet(0),
			I32Load(0),
			LocalGet(1),
			I32Eq,
			LocalSet(2),
		];
		for (object in program.objects) {
			var accepted = [typeId(Obj(object.name))];
			var base = object.base;
			while (base != null) {
				accepted.push(typeId(Obj(base)));
				var next:Null<String> = null;
				for (candidate in program.objects)
					if (candidate.name == base)
						next = candidate.base;
				base = next;
			}
			for (interfaceName in object.interfaces)
				accepted.push(typeId(Virtual(interfaceName)));
			body.push(LocalGet(0));
			body.push(I32Load(0));
			body.push(I32Const(typeId(Obj(object.name))));
			body.push(I32Eq);
			body.push(If(null));
			for (index in 0...accepted.length) {
				body.push(LocalGet(1));
				body.push(I32Const(accepted[index]));
				body.push(I32Eq);
				if (index > 0)
					body.push(I32Or);
			}
			body.push(LocalSet(2));
			body.push(End);
		}
		body.push(End);
		body.push(LocalGet(2));
		body.push(Return);
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}], body));
	}

	static function addStringCharCodeAt(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			I32Load8U(0),
			Return
		]));
	}

	static function addStringConcat(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(4),
			LocalGet(4),
			I32Const(typeId(Bytes)),
			I32Store(0),
			LocalGet(4),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(2),
			MemoryCopy,
			LocalGet(4),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(2),
			I32Add,
			LocalGet(1),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(3),
			MemoryCopy,
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(4),
			Return
		]));
	}

	static function addStringEqual(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			I32Const(0),
			LocalSet(5),
			LocalGet(2),
			LocalGet(3),
			I32Eq,
			If(null),
			I32Const(1),
			LocalSet(5),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(4),
			I32Add,
			I32Load8U(0),
			LocalGet(1),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(4),
			I32Add,
			I32Load8U(0),
			I32Eq,
			If(null),
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(4),
			Br(2),
			Else,
			I32Const(0),
			LocalSet(5),
			Br(3),
			End,
			Else,
			Br(2),
			End,
			End,
			End,
			Else,
			I32Const(0),
			LocalSet(5),
			End,
			LocalGet(5),
			Return
		]));
	}

	static function addArrayCopy(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(2),
			LocalGet(2),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(2),
			LocalGet(1),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(2),
			LocalGet(1),
			I32Const(8),
			I32Add,
			LocalTee(4),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(3),
			LocalGet(2),
			LocalGet(3),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(1),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(2),
			Return
		]));
	}

	static function addArrayJoinBytes(module:WasmModule, name:String, allocator:Int, stringConcat:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			Call(allocator),
			LocalSet(2),
			LocalGet(2),
			I32Const(typeId(Bytes)),
			I32Store(0),
			LocalGet(2),
			I32Const(0),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(2),
			I32Const(0),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32Const(0),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			I32LtS,
			If(null),
			LocalGet(3),
			I32Eqz,
			If(null),
			Else,
			LocalGet(2),
			LocalGet(1),
			Call(stringConcat),
			LocalSet(2),
			End,
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(4),
			I32Mul,
			I32Add,
			I32Load(0),
			Call(stringConcat),
			LocalSet(2),
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(0),
			End,
			End,
			End,
			LocalGet(2),
			Return
		]));
	}

	static function addArrayIndexOf(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, stringEqual:Null<Int>):Int {
		var compare = stringEqual == null ? (elementType == F64 ? F64Eq : I32Eq) : null;
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [{type: I32}, {type: I32}], [
			I32Const(0),
			LocalSet(2),
			I32Const(-1),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalGet(1),
			stringEqual == null ? compare : Call(stringEqual),
			If(null),
			LocalGet(2),
			LocalSet(3),
			Br(3),
			End,
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			Br(1),
			Else,
			End,
			End,
			End,
			LocalGet(3),
			Return
		]));
	}

	static function addArraySlice(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: [I32]}, [for (_ in 0...6) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			LocalGet(3),
			LocalGet(1),
			I32Add,
			LocalSet(4),
			Else,
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(4),
			End,
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(4),
			End,
			LocalGet(2),
			I32Const(0),
			I32LtS,
			If(null),
			LocalGet(3),
			LocalGet(2),
			I32Add,
			LocalSet(5),
			Else,
			LocalGet(2),
			LocalSet(5),
			End,
			LocalGet(5),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(4),
			I32LtS,
			If(null),
			LocalGet(4),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(4),
			I32Sub,
			LocalSet(6),
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(7),
			LocalGet(7),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(7),
			LocalGet(6),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(7),
			LocalGet(6),
			I32Const(8),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(6),
			I32Const(8),
			I32Add,
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(8),
			LocalGet(7),
			LocalGet(8),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(8),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(6),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(7),
			Return
		]));
	}

	static function addArrayConcat(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(4),
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Const(8),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(4),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Const(8),
			I32Add,
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(5),
			LocalGet(4),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(5),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(1),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(4),
			Return
		]));
	}

	static function addArrayPush(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LtS,
			If(null),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalTee(3),
			I32Eqz,
			If(null),
			I32Const(8),
			LocalSet(3),
			Else,
			LocalGet(3),
			I32Const(2),
			I32Mul,
			LocalSet(3),
			End,
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(4),
			LocalGet(4),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(4),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(3),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(1),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalTee(5),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(5),
			Return
		]));
	}

	static function addArrayPop(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [elementType]}, [{type: I32}, {type: I32}, {type: elementType}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(1),
			I32Const(1),
			I32Sub,
			LocalSet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalSet(3),
			LocalGet(0),
			LocalGet(2),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			Else,
			Unreachable,
			End,
			LocalGet(3),
			Return
		]));
	}

	static function addArrayUnshift(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LtS,
			If(null),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalTee(4),
			I32Eqz,
			If(null),
			I32Const(8),
			LocalSet(4),
			Else,
			LocalGet(4),
			I32Const(2),
			I32Mul,
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(5),
			LocalGet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(4),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			LocalGet(2),
			LocalSet(3),
			Block(null),
			Loop(null),
			I32Const(0),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			LocalSet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(1),
			I32Add,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(1),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalTee(3),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(3),
			Return
		]));
	}

	static function addArrayInsert(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, elementType], results: []}, [for (_ in 0...5) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(4),
			Else,
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(4),
			End,
			LocalGet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LtS,
			If(null),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalTee(6),
			I32Eqz,
			If(null),
			I32Const(8),
			LocalSet(6),
			Else,
			LocalGet(6),
			I32Const(2),
			I32Mul,
			LocalSet(6),
			End,
			LocalGet(6),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(7),
			LocalGet(7),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(7),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(6),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			LocalGet(3),
			LocalSet(5),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(5),
			I32LtS,
			If(null),
			LocalGet(5),
			I32Const(1),
			I32Sub,
			LocalSet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(5),
			I32Const(1),
			I32Add,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(5),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(2),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			LocalGet(3),
			I32Const(1),
			I32Add,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET)
		]));
	}

	static function addArrayShift(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [elementType]}, [{type: I32}, {type: elementType}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalSet(2),
			I32Const(1),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			LocalGet(1),
			I32Const(1),
			I32Sub,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			Else,
			Unreachable,
			End,
			LocalGet(2),
			Return
		]));
	}

	static function addArrayResize(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: []}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			Unreachable,
			Else,
			LocalGet(1),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LeS,
			If(null),
			LocalGet(2),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Const(0.0) : I32Const(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			LocalGet(1),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32Const(2),
			I32Mul,
			LocalSet(4),
			LocalGet(4),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(5),
			LocalGet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(4),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			End
		]));
	}

	static function addArrayRemove(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, stringEqual:Null<Int>):Int {
		var compare = stringEqual == null ? (elementType == F64 ? F64Eq : I32Eq) : null;
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			I32Const(0),
			LocalSet(3),
			I32Const(-1),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalGet(1),
			stringEqual == null ? compare : Call(stringEqual),
			If(null),
			LocalGet(3),
			LocalSet(4),
			Br(3),
			End,
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			I32Const(-1),
			LocalGet(4),
			I32LtS,
			If(null),
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			LocalGet(2),
			I32Const(1),
			I32Sub,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			I32Const(1),
			LocalSet(4),
			Else,
			I32Const(0),
			LocalSet(4),
			End,
			LocalGet(4),
			Return
		]));
	}

	static function addArrayReverse(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: []}, [{type: I32}, {type: I32}, {type: I32}, {type: elementType}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalSet(2),
			LocalGet(1),
			I32Const(1),
			I32Sub,
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(2),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalSet(4),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(4),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]));
	}

	static function addArraySplice(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: [I32]}, [for (_ in 0...6) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			LocalGet(3),
			LocalGet(1),
			I32Add,
			LocalSet(4),
			Else,
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(4),
			End,
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(4),
			End,
			LocalGet(2),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(5),
			Else,
			LocalGet(2),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(3),
			LocalGet(4),
			I32Sub,
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalGet(4),
			I32Sub,
			LocalSet(5),
			End,
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(6),
			LocalGet(6),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(6),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(6),
			LocalGet(5),
			I32Const(8),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(5),
			I32Const(8),
			I32Add,
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(8),
			LocalGet(6),
			LocalGet(8),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(8),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(5),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(3),
			LocalGet(4),
			I32Sub,
			LocalGet(5),
			I32Sub,
			LocalSet(7),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			LocalGet(5),
			I32Add,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(7),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(3),
			LocalGet(5),
			I32Sub,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(6),
			Return
		]));
	}

	static function stringBytes(value:String):HaxeBytes {
		var raw = HaxeBytes.ofString(value),
			bytes = HaxeBytes.alloc(WasmLayout.STRING_DATA_OFFSET + raw.length + 1);
		bytes.setInt32(0, typeId(Bytes));
		bytes.setInt32(WasmLayout.STRING_LENGTH_OFFSET, raw.length);
		bytes.setInt32(WasmLayout.ARRAY_CAPACITY_OFFSET, raw.length);
		for (index in 0...raw.length)
			bytes.set(WasmLayout.STRING_DATA_OFFSET + index, raw.get(index));
		return bytes;
	}

	static function zeroValue(type:IrType):Array<WasmInstruction>
		return switch type {
			case F64: [F64Const(0.0)];
			case Void: [];
			default: [I32Const(0)];
		};

	static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);

	static function addAllocator(module:WasmModule):Int {
		var type:WasmFunctionType = {parameters: [I32], results: [I32]};
		return module.addFunction(new WasmFunction("__haxeon_alloc", type, [{type: I32}, {type: I32}, {type: I32}], [
			GlobalGet(0),
			LocalTee(1),
			LocalGet(0),
			I32Add,
			LocalTee(2),
			MemorySize,
			I32Const(65536),
			I32Mul,
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(2),
			I32Const(65535),
			I32Add,
			I32Const(65536),
			I32DivS,
			MemorySize,
			I32Sub,
			MemoryGrow,
			I32Const(-1),
			I32Eq,
			If(null),
			Unreachable,
			End,
			End,
			LocalGet(2),
			GlobalSet(0),
			LocalGet(1),
			Return
		]));
	}

	static function addArrayAllocator(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		var type:WasmFunctionType = {parameters: [I32], results: [I32]};
		return module.addFunction(new WasmFunction(name, type, [{type: I32}, {type: I32}, {type: I32}], [
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(1),
			LocalGet(0),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(1),
			LocalGet(0),
			I32Const(8),
			I32Add,
			LocalTee(2),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(3),
			LocalGet(1),
			LocalGet(3),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(1),
			Return
		]));
	}

	static function arrayStrideForNative(name:String):Null<Int>
		return switch name {
			case "__array_alloc_f64": 8;
			case "__array_alloc_i32", "__array_alloc_bool", "__array_alloc_ref", "__array_alloc_bytes": 4;
			default: null;
		};

	static function hasFunction(program:IrProgram, name:String):Bool {
		for (fn in program.functions)
			if (fn.name == name)
				return true;
		return false;
	}

	static function hasExceptions(program:IrProgram):Bool {
		for (fn in program.functions) {
			for (block in fn.blocks) {
				for (located in block.instructions)
					switch located.value {
						case BeginTry(_, _), EndTry(_), Catch(_):
							return true;
						default:
					}
				if (block.terminator != null)
					switch block.terminator.value {
						case Throw(_), Rethrow(_):
							return true;
						default:
					}
			}
		}
		return false;
	}

	static function reachableFunctions(program:IrProgram, entry:String):Map<String, Bool> {
		var byName:Map<String, IrFunction> = [],
			reachable:Map<String, Bool> = [],
			pending:Array<String> = [entry];
		for (fn in program.functions)
			byName.set(fn.name, fn);
		while (pending.length > 0) {
			var name = pending.pop();
			if (reachable.exists(name) || !byName.exists(name))
				continue;
			reachable.set(name, true);
			var fn = byName.get(name);
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, target, _):
							enqueueFunction(target, byName, pending);
						case StaticClosure(_, target), InstanceClosure(_, target, _):
							enqueueFunction(target, byName, pending);
						case MethodCall(_, object, method, _):
							switch object.type {
								case Obj(objectName): enqueueFunction(findMethod(program, objectName, method), byName, pending);
								case Virtual(interfaceName):
									for (candidate in program.objects)
										if (implementsInterface(program, candidate.name, interfaceName))
											enqueueFunction(findMethod(program, candidate.name, method), byName, pending);
								default:
							}
						default:
					}
		}
		return reachable;
	}

	static function enqueueFunction(name:Null<String>, byName:Map<String, IrFunction>, pending:Array<String>):Void
		if (name != null && byName.exists(name))
			pending.push(name);

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String> {
		for (object in program.objects)
			if (object.name == objectName) {
				for (method in object.methods)
					if (method.name == methodName)
						return method.functionName;
				return object.base == null ? null : findMethod(program, object.base, methodName);
			}
		return null;
	}

	static function implementsInterface(program:IrProgram, objectName:String, interfaceName:String):Bool {
		for (object in program.objects)
			if (object.name == objectName) {
				for (implemented in object.interfaces)
					if (interfaceExtends(program, implemented, interfaceName))
						return true;
				return object.base != null && implementsInterface(program, object.base, interfaceName);
			}
		return false;
	}

	static function interfaceExtends(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (interfaceDecl in program.interfaces)
			if (interfaceDecl.name == actual)
				for (base in interfaceDecl.bases)
					if (interfaceExtends(program, base, expected))
						return true;
		return false;
	}

	static function typeId(type:IrType):Int {
		var text = Std.string(type), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ text.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	static function addDynamicEqual(module:WasmModule, name:String, stringEqual:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			I32Const(0),
			LocalSet(2),
			LocalGet(0),
			LocalGet(1),
			I32Eq,
			If(null),
			I32Const(1),
			LocalSet(2),
			Else,
			LocalGet(0),
			I32Eqz,
			If(null),
			Else,
			LocalGet(1),
			I32Eqz,
			If(null),
			Else,
			LocalGet(0),
			I32Load(0),
			LocalSet(3),
			LocalGet(1),
			I32Load(0),
			LocalSet(4),
			LocalGet(3),
			LocalGet(4),
			I32Eq,
			If(null),
			LocalGet(3),
			I32Const(typeId(Bytes)),
			I32Eq,
			If(null),
			LocalGet(0),
			LocalGet(1),
			Call(stringEqual),
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(typeId(I32)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I32Eq,
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(typeId(Bool)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I32Eq,
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(typeId(F64)),
			I32Eq,
			If(null),
			LocalGet(0),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			F64Eq,
			LocalSet(2),
			Else,
			End,
			End,
			End,
			End,
			Else,
			End,
			End,
			End,
			End,
			LocalGet(2),
			Return
		]));
	}

	static function programFunction(program:IrProgram, name:String):IrFunction {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		throw 'Unknown IR function "$name"';
	}

	static function resultTypes(type:IrType):Array<WasmValueType>
		return type == Void ? [] : [requireValueType(type)];

	public static function requireValueType(type:IrType):WasmValueType
		return switch type {
			case I32, Bool: I32;
			case F64: F64;
			case Bytes, Dyn, TypeRef, Array(_), Enum(_), Obj(_), Abstract(_), Virtual(_), Function(_, _): I32;
			default: throw 'Wasm scalar backend does not yet support IR type ${Std.string(type)}';
		};
}

class WasmFunctionLower {
	static var activeTableSlots:Map<String, Int>;
	static var activeArrayTemps:{
		len:Int,
		capacity:Int,
		data:Int,
		required:Int
	};
	static var activeExceptionState:Null<{
		handler:Int,
		exception:Int,
		saved:Map<Int, Int>,
		blocks:Map<Int, Int>,
		tag:Int
	}>;

	public static function lower(fn:IrFunction, functions:Map<String, Int>, type:WasmFunctionType, layout:WasmLayout, allocator:Int, globals:Map<String, Int>,
			strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>, tableSlots:Map<String, Int>,
			exceptionTag:Null<Int>):WasmFunction {
		activeTableSlots = tableSlots;
		var analysis = new WasmCfgAnalysis(fn),
			placement = new WasmValuePlacement(fn),
			valueLocals = placement.values,
			locals = placement.locals;
		activeArrayTemps = {
			len: placement.allocate(I32),
			capacity: placement.allocate(I32),
			data: placement.allocate(I32),
			required: placement.allocate(I32)
		};
		activeExceptionState = null;
		if (exceptionTag != null && hasExceptions(fn)) {
			var blocks:Map<Int, Int> = [], orderIndex = 0;
			for (id in analysis.graph.order)
				blocks.set(id, orderIndex++);
			var saved:Map<Int, Int> = [];
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case BeginTry(catchBlock, _):
							if (!saved.exists(catchBlock))
								saved.set(catchBlock, placement.allocate(I32));
						default:
					}
			activeExceptionState = {
				handler: placement.allocate(I32),
				exception: placement.allocate(I32),
				saved: saved,
				blocks: blocks,
				tag: exceptionTag
			};
		}
		var predecessor = placement.allocate(I32);
		var structurer = new WasmStructurer(fn),
			body:Array<WasmInstruction> = null;
		if (activeExceptionState == null && structurer.canUseStructured())
			try
				body = lowerStructured(fn, structurer, functions, valueLocals, predecessor, layout, allocator, globals, strings, methods, closureTypes)
			catch (_:Dynamic) {}
		if (body == null) {
			var pc = placement.allocate(I32);
			body = lowerDispatcher(fn, analysis, functions, valueLocals, pc, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		}
		body = WasmOptimizer.optimize(body);
		return new WasmFunction(fn.name, type, locals, body);
	}

	static function lowerStructured(fn:IrFunction, structurer:WasmStructurer, functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [];
		emit(body, [I32Const(-1), LocalSet(predecessor)]);
		if (!emitPath(body, fn.blocks[0].id, null, null, 0, structurer, functions, values, predecessor, [], layout, allocator, globals, strings, methods,
			closureTypes))
			throw 'Unable to structure CFG for ${fn.name}';
		body.push(Unreachable);
		return body;
	}

	static function emitPath(body:Array<WasmInstruction>, start:Int, stop:Null<Int>, activeLoop:Null<Int>, loopDepth:Int, structurer:WasmStructurer,
			functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int, visited:Array<Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>,
			strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):Bool {
		var current = start;
		while (stop == null || current != stop) {
			if (visited.indexOf(current) >= 0)
				return false;
			visited.push(current);
			var block = structurer.analysis.graph.block(current);
			var loop = structurer.loops.get(block.id);
			if (loop != null) {
				if (!emitLoop(body, block, loop, structurer, functions, values, predecessor, visited, layout, allocator, globals, strings, methods,
					closureTypes))
					return false;
				if (stop != null && loop.exit == stop)
					return true;
				current = loop.exit;
				continue;
			}
			emitBlockInstructions(body, block, values, functions, predecessor, layout, allocator, globals, strings, methods, closureTypes);
			if (block.terminator == null)
				return false;
			switch block.terminator.value {
				case Return(value):
					if (value.type != Void)
						body.push(LocalGet(values.get(value.id)));
					body.push(Return);
					return true;
				case Throw(_), Rethrow(_):
					body.push(Unreachable);
					return true;
				case Jump(target):
					if (activeLoop != null && target == activeLoop) {
						setPredecessor(body, predecessor, block.id);
						body.push(Br(loopDepth));
						return true;
					}
					setPredecessor(body, predecessor, block.id);
					if (stop != null && target == stop)
						return true;
					current = target;
				case Branch(condition, yes, no):
					var merge = structurer.analysis.mergeFor(yes, no);
					if (merge == null)
						return false;
					emit(body, [LocalGet(values.get(condition.id)), If(null)]);
					setPredecessor(body, predecessor, block.id);
					if (!emitPath(body, yes, merge, activeLoop, activeLoop == null ? 0 : loopDepth + 1, structurer, functions, values, predecessor,
						visited.copy(), layout, allocator, globals, strings, methods, closureTypes))
						return false;
					body.push(Else);
					setPredecessor(body, predecessor, block.id);
					if (!emitPath(body, no, merge, activeLoop, activeLoop == null ? 0 : loopDepth + 1, structurer, functions, values, predecessor,
						visited.copy(), layout, allocator, globals, strings, methods, closureTypes))
						return false;
					body.push(End);
					if (stop != null && merge == stop)
						return true;
					current = merge;
			}
		}
		return true;
	}

	static function emitLoop(body:Array<WasmInstruction>, block:IrBlock, loop:WasmLoopInfo, structurer:WasmStructurer, functions:Map<String, Int>,
			values:Map<Int, Int>, predecessor:Int, visited:Array<Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>,
			methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):Bool {
		if (block.terminator == null)
			return false;
		var condition:Null<IrValue> = null, whenTrue = -1, whenFalse = -1;
		switch block.terminator.value {
			case Branch(value, yes, no):
				condition = value;
				whenTrue = yes;
				whenFalse = no;
			default:
		}
		if (condition == null || (loop.body != whenTrue && loop.body != whenFalse))
			return false;
		emit(body, [Block(null), Loop(null)]);
		emitBlockInstructions(body, block, values, functions, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		emit(body, [LocalGet(values.get(condition.id)), If(null)]);
		if (loop.body == whenTrue) {
			setPredecessor(body, predecessor, block.id);
			if (!emitPath(body, loop.body, block.id, block.id, 1, structurer, functions, values, predecessor, visited.copy(), layout, allocator, globals,
				strings, methods, closureTypes))
				return false;
			body.push(Else);
			setPredecessor(body, predecessor, block.id);
			emit(body, [Br(2)]);
		} else {
			setPredecessor(body, predecessor, block.id);
			emit(body, [Br(2), Else]);
			if (!emitPath(body, loop.body, block.id, block.id, 1, structurer, functions, values, predecessor, visited.copy(), layout, allocator, globals,
				strings, methods, closureTypes))
				return false;
		}
		emit(body, [End, End, End]);
		return true;
	}

	static function emitBlockInstructions(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, functions:Map<String, Int>, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		for (located in block.instructions)
			switch located.value {
				case Phi(output, inputs):
					WasmPhiLower.emit(body, output, inputs, values, predecessor);
				default:
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes);
			}
	}

	static function lowerDispatcher(fn:IrFunction, analysis:WasmCfgAnalysis, functions:Map<String, Int>, values:Map<Int, Int>, pc:Int, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [], blockIndex:Map<Int, Int> = [];
		var next = 0;
		for (id in analysis.graph.order)
			blockIndex.set(id, next++);
		emit(body, [
			I32Const(blockIndex.get(fn.blocks[0].id)),
			LocalSet(pc),
			I32Const(-1),
			LocalSet(predecessor)
		]);
		if (activeExceptionState != null) {
			emit(body, [I32Const(-1), LocalSet(activeExceptionState.handler)]);
		}
		emit(body, [Block(null), Loop(null)]);
		if (activeExceptionState != null)
			body.push(Try(null));
		for (index in 0...analysis.graph.order.length) {
			var block = analysis.graph.block(analysis.graph.order[index]);
			emit(body, [LocalGet(pc), I32Const(index), I32Eq, If(null)]);
			lowerBlock(body, block, values, functions, pc, predecessor, blockIndex, layout, allocator, globals, strings, methods, closureTypes);
			if (index < analysis.graph.order.length - 1)
				body.push(Else);
			else
				emit(body, [Else, Unreachable]);
		}
		for (_ in 0...analysis.graph.order.length)
			body.push(End);
		if (activeExceptionState == null) {
			emit(body, [Br(0), End, End, Unreachable]);
		} else {
			emit(body, [Br(1), Catch(activeExceptionState.tag), LocalSet(activeExceptionState.exception)]);
			emit(body, [LocalGet(activeExceptionState.handler), I32Const(-1), I32Eq, If(null)]);
			emit(body, [LocalGet(activeExceptionState.exception), Throw(activeExceptionState.tag), Else]);
			var catches = [for (catchBlock in activeExceptionState.saved.keys()) catchBlock];
			catches.sort(function(left, right) return left - right);
			for (catchBlock in catches) {
				emit(body, [
					LocalGet(activeExceptionState.handler),
					I32Const(blockIndex.get(catchBlock)),
					I32Eq,
					If(null)
				]);
				emit(body, [LocalGet(activeExceptionState.handler), LocalSet(pc)]);
				emit(body, [
					LocalGet(activeExceptionState.saved.get(catchBlock)),
					LocalSet(activeExceptionState.handler)
				]);
				body.push(Else);
			}
			body.push(Unreachable);
			for (_ in catches)
				body.push(End);
			emit(body, [End, Br(1), End, End, End, Unreachable]);
		}
		return body;
	}

	static function hasExceptions(fn:IrFunction):Bool {
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _), EndTry(_), Catch(_):
						return true;
					default:
				}
			if (block.terminator != null)
				switch block.terminator.value {
					case Throw(_), Rethrow(_):
						return true;
					default:
				}
		}
		return false;
	}

	static function lowerBlock(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, functions:Map<String, Int>, pc:Int, predecessor:Int,
			blockIndex:Map<Int, Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		for (located in block.instructions)
			switch located.value {
				case Phi(output, inputs):
					WasmPhiLower.emit(body, output, inputs, values, predecessor);
				default:
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes);
			}
		if (block.terminator == null)
			throw 'Missing terminator in Wasm block ${block.id}';
		switch block.terminator.value {
			case Return(value):
				if (value.type != Void)
					body.push(LocalGet(values.get(value.id)));
				body.push(Return);
			case Throw(value), Rethrow(value):
				if (activeExceptionState == null)
					body.push(Unreachable);
				else
					emit(body, [LocalGet(values.get(value.id)), Throw(activeExceptionState.tag)]);
			case Jump(target):
				setPcAndContinue(body, pc, predecessor, block.id, blockIndex.get(target));
			case Branch(condition, yes, no):
				emit(body, [LocalGet(values.get(condition.id)), If(null)]);
				setPcAndContinue(body, pc, predecessor, block.id, blockIndex.get(yes));
				body.push(Else);
				setPcAndContinue(body, pc, predecessor, block.id, blockIndex.get(no));
				body.push(End);
		}
	}

	static function setPcAndContinue(body:Array<WasmInstruction>, pc:Int, predecessor:Int, sourceBlock:Int, target:Int):Void {
		emit(body, [I32Const(sourceBlock), LocalSet(predecessor), I32Const(target), LocalSet(pc)]);
	}

	static function trapOrThrow():Array<WasmInstruction>
		return activeExceptionState == null ? [Unreachable] : [I32Const(0), Throw(activeExceptionState.tag)];

	static function setPredecessor(body:Array<WasmInstruction>, predecessor:Int, sourceBlock:Int):Void
		emit(body, [I32Const(sourceBlock), LocalSet(predecessor)]);

	static function lowerInstruction(body:Array<WasmInstruction>, instruction:IrInstruction, values:Map<Int, Int>, functions:Map<String, Int>,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		switch instruction {
			case Phi(_, _):
			case ConstInt(output, value):
				emit(body, [I32Const(value), LocalSet(values.get(output.id))]);
			case ConstBool(output, value):
				emit(body, [I32Const(value ? 1 : 0), LocalSet(values.get(output.id))]);
			case ConstFloat(output, value):
				emit(body, [F64Const(value), LocalSet(values.get(output.id))]);
			case ConstNull(output):
				emit(body, [I32Const(0), LocalSet(values.get(output.id))]);
			case ConstVoid(_):
			case TypeValue(output, type):
				emit(body, [I32Const(typeId(type)), LocalSet(values.get(output.id))]);
			case ToDyn(output, value):
				switch value.type {
					case I32, Bool:
						emit(body, [
							I32Const(WasmLayout.DYN_I32_SIZE),
							Call(allocator),
							LocalTee(values.get(output.id)),
							I32Const(typeId(value.type)),
							I32Store(0),
							LocalGet(values.get(output.id)),
							LocalGet(values.get(value.id)),
							I32Store(WasmLayout.DYN_PAYLOAD_OFFSET)
						]);
					case F64:
						emit(body, [
							I32Const(WasmLayout.DYN_F64_SIZE),
							Call(allocator),
							LocalTee(values.get(output.id)),
							I32Const(typeId(F64)),
							I32Store(0),
							LocalGet(values.get(output.id)),
							LocalGet(values.get(value.id)),
							F64Store(WasmLayout.DYN_PAYLOAD_OFFSET)
						]);
					default:
						emit(body, [LocalGet(values.get(value.id)), LocalSet(values.get(output.id))]);
				}
			case SafeCast(output, value):
				switch output.type {
					case I32, Bool, F64 if (value.type == Dyn):
						emit(body, [
							LocalGet(values.get(value.id)),
							I32Load(0),
							I32Const(typeId(output.type)),
							I32Eq,
							If(null),
							LocalGet(values.get(value.id)),
							load(output.type, WasmLayout.DYN_PAYLOAD_OFFSET),
							LocalSet(values.get(output.id)),
							Else,
							Unreachable,
							End
						]);
					default:
						emit(body, [LocalGet(values.get(value.id)), LocalSet(values.get(output.id))]);
				}
			case BeginTry(catchBlock, _):
				if (activeExceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				var saved = activeExceptionState.saved.get(catchBlock),
					target = activeExceptionState.blocks.get(catchBlock);
				if (saved == null || target == null)
					throw 'Wasm try handler $catchBlock has no dispatcher state';
				emit(body, [
					LocalGet(activeExceptionState.handler),
					LocalSet(saved),
					I32Const(target),
					LocalSet(activeExceptionState.handler)
				]);
			case EndTry(catchBlock):
				if (activeExceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				var saved = activeExceptionState.saved.get(catchBlock);
				if (saved == null)
					throw 'Wasm try handler $catchBlock has no saved state';
				emit(body, [LocalGet(saved), LocalSet(activeExceptionState.handler)]);
			case Catch(output):
				if (activeExceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				emit(body, [LocalGet(activeExceptionState.exception), LocalSet(values.get(output.id))]);
			case GlobalGet(output, name):
				var global = globals.get(name);
				if (global == null)
					throw 'Wasm global "$name" is not declared';
				emit(body, [GlobalGet(global), LocalSet(values.get(output.id))]);
			case GlobalSet(name, value):
				var global = globals.get(name);
				if (global == null)
					throw 'Wasm global "$name" is not declared';
				emit(body, [LocalGet(values.get(value.id)), GlobalSet(global)]);
			case StaticClosure(output, name):
				var functionIndex = functions.get(name);
				if (functionIndex == null)
					throw 'Wasm closure target "$name" is not emitted';
				var tableSlot = activeTableSlots.get(name);
				if (tableSlot == null)
					throw 'Wasm closure target "$name" has no stable table slot';
				emit(body, [I32Const(tableSlot * 2 + 1), LocalSet(values.get(output.id))]);
			case CallClosure(output, closure, arguments):
				var typeInfo = closureTypes.get(Std.string(closure.type));
				if (typeInfo == null)
					throw 'Wasm closure type ${Std.string(closure.type)} has no indirect signature';
				if (typeInfo.instanceType == null) {
					for (argument in arguments)
						body.push(LocalGet(values.get(argument.id)));
					body.push(LocalGet(values.get(closure.id)));
					body.push(I32Const(1));
					body.push(I32ShrU);
					body.push(CallIndirect(typeInfo.staticType));
					if (output.type != Void)
						body.push(LocalSet(values.get(output.id)));
				} else {
					body.push(LocalGet(values.get(closure.id)));
					body.push(I32Const(1));
					body.push(I32And);
					body.push(If(null));
					for (argument in arguments)
						body.push(LocalGet(values.get(argument.id)));
					body.push(LocalGet(values.get(closure.id)));
					body.push(I32Const(1));
					body.push(I32ShrU);
					body.push(CallIndirect(typeInfo.staticType));
					if (output.type != Void)
						body.push(LocalSet(values.get(output.id)));
					body.push(Else);
					body.push(LocalGet(values.get(closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET));
					for (argument in arguments)
						body.push(LocalGet(values.get(argument.id)));
					body.push(LocalGet(values.get(closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_FUNCTION_OFFSET));
					body.push(CallIndirect(typeInfo.instanceType));
					if (output.type != Void)
						body.push(LocalSet(values.get(output.id)));
					body.push(End);
				}
			case InstanceClosure(output, name, receiver):
				var functionIndex = functions.get(name);
				if (functionIndex == null)
					throw 'Wasm instance closure target "$name" is not emitted';
				var tableSlot = activeTableSlots.get(name);
				if (tableSlot == null)
					throw 'Wasm instance closure target "$name" has no stable table slot';
				emit(body, [
					I32Const(WasmLayout.CLOSURE_SIZE),
					Call(allocator),
					LocalTee(values.get(output.id)),
					I32Const(tableSlot),
					I32Store(WasmLayout.CLOSURE_FUNCTION_OFFSET),
					LocalGet(values.get(output.id)),
					LocalGet(values.get(receiver.id)),
					I32Store(WasmLayout.CLOSURE_RECEIVER_OFFSET)
				]);
			case ToVirtual(output, value):
				emit(body, [LocalGet(values.get(value.id)), LocalSet(values.get(output.id))]);
			case MethodCall(output, object, methodName, arguments):
				switch object.type {
					case Obj(objectName):
						var functionName = findMethod(layout.program, objectName, methodName),
							functionIndex = functionName == null ? null : functions.get(functionName);
						if (functionIndex == null)
							throw 'Wasm method target "$objectName.$methodName" is not emitted';
						body.push(LocalGet(values.get(object.id)));
						for (argument in arguments)
							body.push(LocalGet(values.get(argument.id)));
						body.push(Call(functionIndex));
						if (output.type != Void) body.push(LocalSet(values.get(output.id)));
					case Virtual(interfaceName):
						var targets = virtualTargets(layout, interfaceName, methodName, functions);
						if (targets.length == 0)
							throw 'Wasm interface method "$interfaceName.$methodName" has no implementations';
						for (index in 0...targets.length) {
							var target = targets[index];
							emit(body, [
								LocalGet(values.get(object.id)),
								I32Load(0),
								I32Const(typeId(Obj(target.typeName))),
								I32Eq,
								If(null),
								LocalGet(values.get(object.id))
							]);
							for (argument in arguments)
								body.push(LocalGet(values.get(argument.id)));
							body.push(Call(target.functionIndex));
							if (output.type != Void)
								body.push(LocalSet(values.get(output.id)));
							if (index < targets.length - 1)
								body.push(Else);
							else
								emit(body, [Else, Unreachable]);
						}
						for (_ in targets)
							body.push(End);
					default:
						throw 'Wasm method call requires an object or virtual receiver';
				}
			case ConstString(output, value):
				var pointer = strings.get(value);
				if (pointer == null)
					throw 'Wasm string literal was not placed in a data segment';
				emit(body, [I32Const(pointer), LocalSet(values.get(output.id))]);
			case MakeEnum(output, typeName, constructor, arguments):
				var enumLayout = layout.enumType(typeName);
				emit(body, [
					I32Const(enumLayout.size),
					Call(allocator),
					LocalTee(values.get(output.id)),
					I32Const(typeId(Enum(typeName))),
					I32Store(0),
					LocalGet(values.get(output.id)),
					I32Const(constructor),
					I32Store(WasmLayout.HEADER_SIZE)
				]);
				var offset = WasmLayout.HEADER_SIZE + 4;
				for (argument in arguments) {
					offset = align(offset, WasmLayout.alignmentOf(argument.type));
					emit(body, [
						LocalGet(values.get(output.id)),
						I32Const(offset),
						I32Add,
						LocalGet(values.get(argument.id)),
						store(argument.type, 0)
					]);
					offset += WasmLayout.sizeOf(argument.type);
				}
			case EnumIndex(output, value):
				emit(body, [
					LocalGet(values.get(value.id)),
					I32Load(WasmLayout.HEADER_SIZE),
					LocalSet(values.get(output.id))
				]);
			case EnumField(output, value, constructor, field):
				var enumType = switch value.type {
					case Enum(name): name;
					default: throw 'Wasm enum field access requires an enum value, got ${Std.string(value.type)}';
				};
				var fieldLayout = layout.enumField(enumType, constructor, field);
				emit(body, [
					LocalGet(values.get(value.id)),
					I32Const(fieldLayout.offset),
					I32Add,
					load(fieldLayout.type, 0),
					LocalSet(values.get(output.id))
				]);
			case IntToFloat(output, value):
				emit(body, [LocalGet(values.get(value.id)), F64ConvertI32S, LocalSet(values.get(output.id))]);
			case NewObject(output, typeName):
				emit(body, [
					I32Const(layout.object(typeName).size),
					Call(allocator),
					LocalTee(values.get(output.id)),
					I32Const(typeId(Obj(typeName))),
					I32Store(0)
				]);
			case FieldGet(output, object, fieldName):
				var field = objectField(layout, object, fieldName);
				emit(body, [
					LocalGet(values.get(object.id)),
					load(field.type, field.offset),
					LocalSet(values.get(output.id))
				]);
			case FieldSet(object, fieldName, value):
				var field = objectField(layout, object, fieldName);
				emit(body, [
					LocalGet(values.get(object.id)),
					LocalGet(values.get(value.id)),
					store(field.type, field.offset)
				]);
			case ArrayGet(output, array, index):
				var element = arrayElement(array),
					stride = WasmLayout.arrayStride(element);
				var arrayBody:Array<WasmInstruction> = [LocalGet(values.get(index.id)), I32Const(0), I32LtS, If(null)];
				arrayBody = arrayBody.concat(trapOrThrow());
				arrayBody = arrayBody.concat([
					Else,
					LocalGet(values.get(index.id)),
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
					I32LtS,
					If(null),
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
					LocalGet(values.get(index.id)),
					I32Const(stride),
					I32Mul,
					I32Add,
					load(element, 0),
					LocalSet(values.get(output.id)),
				]);
				arrayBody.push(Else);
				arrayBody = arrayBody.concat(trapOrThrow());
				arrayBody = arrayBody.concat([End, End]);
				emit(body, arrayBody);
			case ArraySet(array, index, value):
				var element = arrayElement(array),
					stride = WasmLayout.arrayStride(element);
				var arrayBody:Array<WasmInstruction> = [LocalGet(values.get(index.id)), I32Const(0), I32LtS, If(null)];
				arrayBody = arrayBody.concat(trapOrThrow());
				arrayBody = arrayBody.concat([
					Else,
					LocalGet(values.get(index.id)),
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
					I32LtS,
					If(null),
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
					LocalGet(values.get(index.id)),
					I32Const(stride),
					I32Mul,
					I32Add,
					LocalGet(values.get(value.id)),
					store(element, 0),
					Else
				]);
				arrayBody = arrayBody.concat([
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
					LocalSet(activeArrayTemps.len),
					LocalGet(values.get(index.id)),
					I32Const(1),
					I32Add,
					LocalSet(activeArrayTemps.required),
					LocalGet(activeArrayTemps.required),
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
					I32LeS,
					If(null),
					Else,
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
					I32Const(2),
					I32Mul,
					LocalSet(activeArrayTemps.capacity),
					LocalGet(activeArrayTemps.capacity),
					LocalGet(activeArrayTemps.required),
					I32LtS,
					If(null),
					LocalGet(activeArrayTemps.required),
					LocalSet(activeArrayTemps.capacity),
					End,
					LocalGet(activeArrayTemps.capacity),
					I32Const(stride),
					I32Mul,
					Call(allocator),
					LocalSet(activeArrayTemps.data),
					LocalGet(activeArrayTemps.data),
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
					LocalGet(activeArrayTemps.len),
					I32Const(stride),
					I32Mul,
					MemoryCopy,
					LocalGet(values.get(array.id)),
					LocalGet(activeArrayTemps.data),
					I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
					LocalGet(values.get(array.id)),
					LocalGet(activeArrayTemps.capacity),
					I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
					End,
					Block(null),
					Loop(null),
					LocalGet(activeArrayTemps.len),
					LocalGet(activeArrayTemps.required),
					I32LtS,
					If(null),
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
					LocalGet(activeArrayTemps.len),
					I32Const(stride),
					I32Mul,
					I32Add,
					element == F64 ? F64Const(0.0) : I32Const(0),
					element == F64 ? F64Store(0) : I32Store(0),
					LocalGet(activeArrayTemps.len),
					I32Const(1),
					I32Add,
					LocalSet(activeArrayTemps.len),
					Br(1),
					Else,
					Br(2),
					End,
					End,
					End,
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
					LocalGet(values.get(index.id)),
					I32Const(stride),
					I32Mul,
					I32Add,
					LocalGet(values.get(value.id)),
					store(element, 0),
					LocalGet(values.get(array.id)),
					LocalGet(activeArrayTemps.required),
					I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
					End,
					End
				]);
				emit(body, arrayBody);
			case ArraySize(output, array):
				emit(body, [
					LocalGet(values.get(array.id)),
					I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
					LocalSet(values.get(output.id))
				]);
			case Add(output, left, right):
				binary(body, output, left, right, values, left.type == F64 ? F64Add : I32Add);
			case Sub(output, left, right):
				binary(body, output, left, right, values, left.type == F64 ? F64Sub : I32Sub);
			case Mul(output, left, right):
				binary(body, output, left, right, values, left.type == F64 ? F64Mul : I32Mul);
			case Div(output, left, right):
				binary(body, output, left, right, values, left.type == F64 ? F64Div : I32DivS);
			case Mod(output, left, right):
				binary(body, output, left, right, values, I32RemS);
			case BitAnd(output, left, right):
				binary(body, output, left, right, values, I32And);
			case BitXor(output, left, right):
				binary(body, output, left, right, values, I32Xor);
			case BitOr(output, left, right):
				binary(body, output, left, right, values, I32Or);
			case ShiftLeft(output, left, right):
				binary(body, output, left, right, values, I32Shl);
			case ShiftRight(output, left, right):
				binary(body, output, left, right, values, I32ShrS);
			case UnsignedShiftRight(output, left, right):
				binary(body, output, left, right, values, I32ShrU);
			case Less(output, left, right):
				binary(body, output, left, right, values, left.type == F64 ? F64Lt : I32LtS);
			case LessEqual(output, left, right):
				binary(body, output, left, right, values, left.type == F64 ? F64Le : I32LeS);
			case Equal(output, left, right):
				binary(body, output, left, right, values, left.type == F64 ? F64Eq : I32Eq);
			case Call(output, name, arguments):
				for (argument in arguments)
					body.push(LocalGet(values.get(argument.id)));
				var functionIndex = functions.get(name);
				if (functionIndex == null)
					throw 'Wasm call to unsupported native or missing function "$name"';
				body.push(Call(functionIndex));
				if (output.type != Void)
					body.push(LocalSet(values.get(output.id)));
		}
	}

	static function objectField(layout:WasmLayout, object:IrValue, fieldName:String):WasmFieldLayout
		return switch object.type {
			case Obj(name): layout.field(name, fieldName);
			default: throw 'Wasm field access requires an object reference, got ${Std.string(object.type)}';
		};

	static function arrayElement(array:IrValue):IrType
		return switch array.type {
			case Array(element): element;
			default: throw 'Wasm array access requires an Array reference, got ${Std.string(array.type)}';
		};

	static function load(type:IrType, offset:Int):WasmInstruction
		return type == F64 ? F64Load(offset) : I32Load(offset);

	static function store(type:IrType, offset:Int):WasmInstruction
		return type == F64 ? F64Store(offset) : I32Store(offset);

	static function virtualTargets(layout:WasmLayout, interfaceName:String, methodName:String,
			functions:Map<String, Int>):Array<{typeName:String, functionIndex:Int}> {
		var result:Array<{typeName:String, functionIndex:Int}> = [];
		for (object in layout.program.objects) {
			if (!implementsInterface(layout.program, object.name, interfaceName))
				continue;
			var functionName = findMethod(layout.program, object.name, methodName);
			if (functionName != null) {
				var functionIndex = functions.get(functionName);
				if (functionIndex != null)
					result.push({typeName: object.name, functionIndex: functionIndex});
			}
		}
		return result;
	}

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String> {
		for (object in program.objects)
			if (object.name == objectName) {
				for (method in object.methods)
					if (method.name == methodName)
						return method.functionName;
				return object.base == null ? null : findMethod(program, object.base, methodName);
			}
		return null;
	}

	static function implementsInterface(program:IrProgram, objectName:String, interfaceName:String):Bool {
		for (object in program.objects)
			if (object.name == objectName) {
				for (implemented in object.interfaces)
					if (interfaceExtends(program, implemented, interfaceName))
						return true;
				return object.base != null && implementsInterface(program, object.base, interfaceName);
			}
		return false;
	}

	static function interfaceExtends(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (interfaceDecl in program.interfaces)
			if (interfaceDecl.name == actual)
				for (base in interfaceDecl.bases)
					if (interfaceExtends(program, base, expected))
						return true;
		return false;
	}

	static function typeId(type:IrType):Int {
		var text = Std.string(type), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ text.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);

	static function binary(body:Array<WasmInstruction>, output:IrValue, left:IrValue, right:IrValue, values:Map<Int, Int>, op:WasmInstruction):Void {
		emit(body, [
			LocalGet(values.get(left.id)),
			LocalGet(values.get(right.id)),
			op,
			LocalSet(values.get(output.id))
		]);
	}

	static function emit(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function outputOf(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(output, _), ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), ConstBool(output, _),
				ConstNull(output), TypeValue(output, _), ToDyn(output, _), IntToFloat(output, _), SafeCast(output, _), Catch(output), GlobalGet(output, _),
				Add(output, _, _), Sub(output, _, _), Mul(output, _, _), Div(output, _, _), Mod(output, _, _), BitAnd(output, _, _), BitXor(output, _, _),
				BitOr(output, _, _), ShiftLeft(output, _, _), ShiftRight(output, _, _), UnsignedShiftRight(output, _, _), Less(output, _, _),
				LessEqual(output, _, _), Equal(output, _, _), Call(output, _, _), StaticClosure(output, _), InstanceClosure(output, _, _),
				CallClosure(output, _, _), ToVirtual(output, _), MethodCall(output, _, _, _), NewObject(output, _), FieldGet(output, _, _),
				ArrayGet(output, _, _), ArraySize(output, _), MakeEnum(output, _, _, _), EnumIndex(output, _), EnumField(output, _, _, _): output;
			case BeginTry(_, _), EndTry(_), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _): null;
		};
}
