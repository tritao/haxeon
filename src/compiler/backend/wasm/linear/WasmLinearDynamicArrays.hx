package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
import compiler.backend.wasm.WasmFunctionBuilder.WasmLocalRef;

/**
 * Exact array storage with `Array<Dynamic>` views, ported from `native/runtime/arrays.c`.
 *
 * Every array header records its storage element type (`ARRAY_ELEMENT_TYPE_OFFSET`). Concrete
 * arrays keep unboxed storage; `Array<Dynamic>` operations read and write through the storage
 * element type, boxing on read and checking or unboxing on write. Dynamic storage takes its
 * element type on the first concrete view (`__array_check_cast`), after every element has been
 * validated, so a rejected element leaves the array untouched.
 */
class WasmLinearDynamicArrays {
	static final OPERATIONS = [
		"__array_alloc_typed_ref",
		"__array_check_cast",
		"__array_get_any",
		"__array_set_any",
		"__array_push_any",
		"__array_unshift_any",
		"__array_insert_any",
		"__array_pop_any",
		"__array_shift_any",
		"__array_index_of_any",
		"__array_remove_any",
		"__array_concat_any",
		"__array_copy_any",
		"__array_slice_any",
		"__array_splice_any",
		"__array_reverse_any",
		"__array_resize_any"
	];

	static final MESSAGES = [
		"Array element type mismatch: ",
		" -> ",
		" (element ",
		" is ",
		")",
		"Can't cast ",
		" to ",
		"Array index out of bounds",
		"Array.pop on an empty array",
		"Array.shift on an empty array",
		"Array.resize length must be non-negative",
		"Int",
		"Int64",
		"Float",
		"Bool",
		"String",
		"Dynamic",
		"Array",
		"Function",
		"null",
		"Object"
	];

	final context:WasmLinearContext;
	final module:WasmModule;
	final program:IrProgram;
	final elementTypes:Array<IrType>;
	final throws:Bool;
	final helpers:Map<String, Int> = [];

	function new(context:WasmLinearContext) {
		this.context = context;
		module = context.module;
		program = context.program;
		elementTypes = viewedElementTypes(program);
		throws = WasmModuleSupport.hasExceptions(program);
	}

	static function uses(program:IrProgram):Bool {
		for (native in program.natives)
			if (OPERATIONS.indexOf(native.name) >= 0)
				return true;
		return false;
	}

	/** Static strings the runtime needs for diagnostics; empty unless dynamic views are used. */
	public static function runtimeStrings(program:IrProgram):Array<String> {
		if (!uses(program))
			return [];
		var result = MESSAGES.copy();
		for (type in viewedElementTypes(program))
			result.push(staticTypeName(type));
		for (object in program.objects)
			result.push(object.name);
		for (enumDecl in program.enums)
			result.push(enumDecl.name);
		return result;
	}

	/** Emit every dynamic-view native the program declares. Concrete array natives must exist. */
	public static function register(context:WasmLinearContext):Void {
		if (!uses(context.program))
			return;
		var runtime = new WasmLinearDynamicArrays(context);
		for (native in context.program.natives)
			if (OPERATIONS.indexOf(native.name) >= 0 && !context.functions.exists(native.name))
				context.functions.set(native.name, runtime.emit(native.name));
	}

	/** Element types that `__array_check_cast` and typed reference allocation receive as type values. */
	static function viewedElementTypes(program:IrProgram):Array<IrType> {
		var result:Array<IrType> = [], seen:Map<Int, Bool> = [];
		for (fn in program.functions) {
			var typeValues:Map<Int, IrType> = [];
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case TypeValue(output, type):
							typeValues.set(output.id, type);
						default:
					}
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, "__array_check_cast" | "__array_alloc_typed_ref", arguments) if (arguments.length == 2):
							var type = typeValues.get(arguments[1].id);
							if (type != null && !seen.exists(typeId(type))) {
								seen.set(typeId(type), true);
								result.push(type);
							}
						default:
					}
		}
		return result;
	}

	static inline function typeId(type:IrType):Int
		return WasmModuleSupport.typeId(type);

	/** Haxe spelling for array diagnostics, as `realtime_array_type_name` prints it. */
	static function staticTypeName(type:IrType):String
		return switch type {
			case I32: "Int";
			case I64: "Int64";
			case F64: "Float";
			case Bool: "Bool";
			case Bytes: "String";
			case Dyn: "Dynamic";
			case Array(_): "Array";
			case Function(_, _): "Function";
			case Obj(name), Enum(name), Virtual(name), Abstract(name): name;
			default: "Object";
		};

	function string(value:String):Int {
		var offset = context.strings.get(value);
		if (offset == null)
			throw 'Linear Wasm dynamic array runtime string "$value" was not registered';
		return offset;
	}

	function concrete(name:String):Int {
		var index = context.functions.get(name);
		if (index == null)
			throw 'Linear Wasm dynamic array runtime requires "$name"';
		return index;
	}

	function helper(name:String, create:String->Int):Int {
		var index = helpers.get(name);
		if (index == null) {
			index = create(name);
			helpers.set(name, index);
		}
		return index;
	}

	function emit(name:String):Int
		return switch name {
			case "__array_alloc_typed_ref": addAllocTypedRef(name);
			case "__array_check_cast": addCheckCast(name);
			case "__array_get_any": addGet(name);
			case "__array_set_any": addSet(name);
			case "__array_push_any": addValueOperation(name, "push", false);
			case "__array_unshift_any": addValueOperation(name, "unshift", false);
			case "__array_insert_any": addValueOperation(name, "insert", true);
			case "__array_pop_any": addTake(name, "pop", false);
			case "__array_shift_any": addTake(name, "shift", true);
			case "__array_index_of_any": indexOf();
			case "__array_remove_any": addRemove(name);
			case "__array_concat_any": addConcat(name);
			case "__array_copy_any": addStorageOperation(name, "copy", [I32], [I32]);
			case "__array_slice_any": addStorageOperation(name, "slice", [I32, I32, I32], [I32]);
			case "__array_splice_any": addStorageOperation(name, "splice", [I32, I32, I32], [I32]);
			case "__array_reverse_any": addStorageOperation(name, "reverse", [I32], []);
			case "__array_resize_any": addResize(name);
			default: throw 'Unknown dynamic array operation "$name"';
		};

	// Shared emission helpers.

	static function loadElementType(builder:WasmFunctionBuilder, array:WasmLocalRef):Void {
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET));
	}

	/** Push `local == typeId(type)` for each listed type, or-ed together. */
	static function isOneOf(builder:WasmFunctionBuilder, local:WasmLocalRef, types:Array<IrType>):Void {
		for (index in 0...types.length) {
			builder.localGet(local);
			builder.i32Const(typeId(types[index]));
			builder.emit(I32Eq);
			if (index > 0)
				builder.emit(I32Or);
		}
	}

	/** Dispatch on the storage element type: i32-slot primitives, f64, i64, then references. */
	static function byStorage(builder:WasmFunctionBuilder, elementType:WasmLocalRef, i32:WasmFunctionBuilder->Void, f64:WasmFunctionBuilder->Void,
			i64:WasmFunctionBuilder->Void, reference:WasmFunctionBuilder->Void, ?result:WasmValueType):Void {
		isOneOf(builder, elementType, [I32, Bool]);
		builder.ifElse(i32, function(builder) {
			isOneOf(builder, elementType, [F64]);
			builder.ifElse(f64, function(builder) {
				isOneOf(builder, elementType, [I64]);
				builder.ifElse(i64, reference, result);
			}, result);
		}, result);
	}

	/** Address of element `index` given its stride local. */
	static function slotAddress(builder:WasmFunctionBuilder, array:WasmLocalRef, index:WasmLocalRef, stride:WasmLocalRef):Void {
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(index);
		builder.localGet(stride);
		builder.emit(I32Mul);
		builder.i32Add();
	}

	/** Concatenate strings produced by each part; the result is left on the stack. */
	function concatenate(builder:WasmFunctionBuilder, parts:Array<WasmFunctionBuilder->Void>):Void {
		var concat = stringConcat();
		parts[0](builder);
		for (index in 1...parts.length) {
			parts[index](builder);
			builder.call(builder.functionRef(concat));
		}
	}

	function literal(value:String):WasmFunctionBuilder->Void {
		var offset = string(value);
		return function(builder) builder.i32Const(offset);
	}

	function typeNameOf(local:WasmLocalRef):WasmFunctionBuilder->Void {
		var name = typeName();
		return function(builder) {
			builder.localGet(local);
			builder.call(builder.functionRef(name));
		};
	}

	function valueTypeNameOf(local:WasmLocalRef):WasmFunctionBuilder->Void {
		var name = valueTypeName();
		return function(builder) {
			builder.localGet(local);
			builder.call(builder.functionRef(name));
		};
	}

	/** Raise the message on the stack; the enclosing path is unreachable afterwards. */
	function raise(builder:WasmFunctionBuilder):Void {
		builder.call(builder.functionRef(fail()));
		builder.emit(Unreachable);
	}

	// Runtime helper functions.

	function stringConcat():Int {
		var existing = context.functions.get("__string_concat");
		return existing != null ? existing : helper("__haxeon_array_string_concat",
			name -> WasmLinearRuntime.addStringConcat(module, name, context.allocatorFunction));
	}

	function dynamicEqual():Int {
		var existing = context.functions.get("__dynamic_equal");
		if (existing != null)
			return existing;
		return helper("__haxeon_array_dynamic_equal", function(name) {
			var stringEqual = context.functions.get("__string_equal");
			if (stringEqual == null)
				stringEqual = helper("__haxeon_array_string_equal", equalName -> WasmLinearRuntime.addStringEqual(module, equalName));
			return WasmLinearRuntime.addDynamicEqual(module, name, stringEqual);
		});
	}

	function typeTest():Int
		return helper("__haxeon_array_type_test", name -> WasmLinearRuntime.addTypeTest(module, name, program));

	function intToString():Int
		return helper("__haxeon_array_i32_to_string", name -> WasmLinearRuntime.addIntToString(module, name, context.allocatorFunction));

	/** Throw the message as a Haxe exception, or trap when the program cannot catch one. */
	function fail():Int
		return helper("__haxeon_array_fail", function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: []}),
				message = builder.parameter("message", 0);
			if (throws) {
				builder.localGet(message);
				builder.emit(Throw(0));
			} else
				builder.emit(Unreachable);
			return module.addFunction(builder.finish());
		});

	function typeName():Int
		return helper("__haxeon_array_type_name", function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
				id = builder.parameter("typeId", 0),
				named:Array<{id:Int, name:String}> = [],
				seen:Map<Int, Bool> = [];
			function add(type:IrType, name:String):Void
				if (!seen.exists(typeId(type))) {
					seen.set(typeId(type), true);
					named.push({id: typeId(type), name: name});
				}
			for (type in ([I32, I64, F64, Bool, Bytes, Dyn, Array(Dyn)] : Array<IrType>))
				add(type, staticTypeName(type));
			for (object in program.objects)
				add(Obj(object.name), object.name);
			for (enumDecl in program.enums)
				add(Enum(enumDecl.name), enumDecl.name);
			for (type in elementTypes)
				add(type, staticTypeName(type));
			for (entry in named) {
				builder.localGet(id);
				builder.i32Const(entry.id);
				builder.emit(I32Eq);
				builder.if_(function(builder) {
					builder.i32Const(string(entry.name));
					builder.return_();
				});
			}
			builder.i32Const(string("Object"));
			builder.return_();
			return module.addFunction(builder.finish());
		});

	function valueTypeName():Int
		return helper("__haxeon_array_value_type_name", function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
				value = builder.parameter("value", 0),
				names = typeName();
			builder.localGet(value);
			builder.i32Eqz();
			builder.if_(function(builder) {
				builder.i32Const(string("null"));
				builder.return_();
			});
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.call(builder.functionRef(names));
			builder.return_();
			return module.addFunction(builder.finish());
		});

	/** Storage stride: eight bytes for Float and Int64 storage, four otherwise. */
	function stride():Int
		return helper("__haxeon_array_stride", function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
				array = builder.parameter("array", 0),
				elementType = builder.local("elementType", I32);
			loadElementType(builder, array);
			builder.localSet(elementType);
			isOneOf(builder, elementType, [F64, I64]);
			builder.ifElse(function(builder) builder.i32Const(8), function(builder) builder.i32Const(4), I32);
			builder.return_();
			return module.addFunction(builder.finish());
		});

	/** Read element `index` as a dynamic value, boxing primitive storage (`realtime_any_read`). */
	function box():Int
		return helper("__haxeon_array_box", function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
				array = builder.parameter("array", 0),
				index = builder.parameter("index", 1),
				elementType = builder.local("elementType", I32),
				boxed = builder.local("boxed", I32),
				allocator = context.allocatorFunction;
			function allocateBox(builder:WasmFunctionBuilder, size:Int):Void {
				builder.i32Const(size);
				builder.call(builder.functionRef(allocator));
				builder.localTee(boxed);
				builder.localGet(elementType);
				builder.emit(I32Store(0));
				builder.localGet(boxed);
				builder.localGet(array);
				builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
				builder.localGet(index);
				builder.i32Const(size == WasmLayout.DYN_I32_SIZE ? 4 : 8);
				builder.emit(I32Mul);
				builder.i32Add();
			}
			loadElementType(builder, array);
			builder.localSet(elementType);
			byStorage(builder, elementType, function(builder) {
				allocateBox(builder, WasmLayout.DYN_I32_SIZE);
				builder.emit(I32Load(0));
				builder.emit(I32Store(WasmLayout.DYN_PAYLOAD_OFFSET));
			}, function(builder) {
				allocateBox(builder, WasmLayout.DYN_F64_SIZE);
				builder.emit(F64Load(0));
				builder.emit(F64Store(WasmLayout.DYN_PAYLOAD_OFFSET));
			}, function(builder) {
				allocateBox(builder, WasmLayout.DYN_I64_SIZE);
				builder.emit(I64Load(0));
				builder.emit(I64Store(WasmLayout.DYN_PAYLOAD_OFFSET));
			}, function(builder) {
				builder.localGet(array);
				builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
				builder.localGet(index);
				builder.i32Const(4);
				builder.emit(I32Mul);
				builder.i32Add();
				builder.emit(I32Load(0));
				builder.localSet(boxed);
			});
			builder.localGet(boxed);
			builder.return_();
			return module.addFunction(builder.finish());
		});

	/**
	 * True when a dynamic value converts to the element type without changing its meaning
	 * (`realtime_array_accepts`): Int storage never truncates a Float, only Bool fills Bool storage,
	 * and class, enum and array storage require a matching runtime type.
	 */
	function accepts():Int
		return helper("__haxeon_array_accepts", function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
				target = builder.parameter("target", 0),
				value = builder.parameter("value", 1),
				valueType = builder.local("valueType", I32),
				test = typeTest();
			function when(types:Array<IrType>, body:WasmFunctionBuilder->Void):Void {
				isOneOf(builder, target, types);
				builder.if_(body);
			}
			function returnNullOr(builder:WasmFunctionBuilder, check:WasmFunctionBuilder->Void):Void {
				builder.localGet(value);
				builder.i32Eqz();
				builder.if_(function(builder) {
					builder.i32Const(1);
					builder.return_();
				});
				check(builder);
				builder.return_();
			}
			builder.localGet(value);
			builder.i32Eqz();
			builder.ifElse(function(builder) builder.i32Const(0), function(builder) {
				builder.localGet(value);
				builder.emit(I32Load(0));
			}, I32);
			builder.localSet(valueType);
			when([I32, I64], function(builder) {
				isOneOf(builder, valueType, [I32, I64]);
				builder.return_();
			});
			when([F64], function(builder) {
				isOneOf(builder, valueType, [I32, I64, F64]);
				builder.return_();
			});
			when([Bool], function(builder) {
				isOneOf(builder, valueType, [Bool]);
				builder.return_();
			});
			when([Bytes], function(builder) returnNullOr(builder, function(builder) isOneOf(builder, valueType, [Bytes])));
			for (type in elementTypes)
				switch type {
					case Obj(_) | Virtual(_) if (nominal(type)):
						when([type], function(builder) returnNullOr(builder, function(builder) {
							builder.localGet(value);
							builder.localGet(target);
							builder.call(builder.functionRef(test));
						}));
					case Enum(_):
						when([type], function(builder) returnNullOr(builder, function(builder) isOneOf(builder, valueType, [type])));
					case Array(_):
						when([type], function(builder) returnNullOr(builder, function(builder) isOneOf(builder, valueType, [Array(Dyn)])));
					default:
				}
			// Dynamic, structural and function storage converts through the ordinary dynamic cast.
			builder.i32Const(1);
			builder.return_();
			return module.addFunction(builder.finish());
		});

	/** Classes and interfaces carry a runtime type test; structural types convert unchecked. */
	function nominal(type:IrType):Bool
		return switch type {
			case Obj(_): true;
			case Virtual(name): Lambda.exists(program.interfaces, candidate -> candidate.name == name);
			default: false;
		};

	/** Raise "Can't cast <value> to <element>" for a value that storage cannot hold. */
	function raiseCast(builder:WasmFunctionBuilder, value:WasmLocalRef, elementType:WasmLocalRef):Void {
		concatenate(builder, [
			literal("Can't cast "),
			valueTypeNameOf(value),
			literal(" to "),
			typeNameOf(elementType)
		]);
		raise(builder);
	}

	/**
	 * Convert a dynamic value for storage of the array's element type (`realtime_any_encode`):
	 * primitive storage unboxes numbers as a dynamic cast would, reference storage checks the value.
	 */
	function encode(kind:WasmValueType, reference:Bool):Int {
		var suffix = reference ? "ref" : switch kind {
			case F64: "f64";
			case I64: "i64";
			default: "i32";
		};
		return helper('__haxeon_array_encode_$suffix', function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [kind]}),
				array = builder.parameter("array", 0),
				value = builder.parameter("value", 1),
				elementType = builder.local("elementType", I32),
				valueType = builder.local("valueType", I32);
			loadElementType(builder, array);
			builder.localSet(elementType);
			if (reference) {
				var check = accepts();
				isOneOf(builder, elementType, [Dyn]);
				builder.localGet(elementType);
				builder.localGet(value);
				builder.call(builder.functionRef(check));
				builder.emit(I32Or);
				builder.if_(function(builder) {
					builder.localGet(value);
					builder.return_();
				});
				raiseCast(builder, value, elementType);
				return module.addFunction(builder.finish());
			}
			builder.localGet(value);
			builder.i32Eqz();
			builder.if_(function(builder) {
				builder.emit(kind == F64 ? F64Const(0.0) : kind == I64 ? I64Const(0) : I32Const(0));
				builder.return_();
			});
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.localSet(valueType);
			function from(types:Array<IrType>, convert:WasmFunctionBuilder->Void):Void {
				isOneOf(builder, valueType, types);
				builder.if_(function(builder) {
					builder.localGet(value);
					convert(builder);
					builder.return_();
				});
			}
			switch kind {
				case F64:
					from([I32, Bool], function(builder) {
						builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.emit(F64ConvertI32S);
					});
					from([F64], builder -> builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET)));
					from([I64], function(builder) {
						builder.emit(I64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.emit(F64ConvertI64S);
					});
				case I64:
					from([I32, Bool], function(builder) {
						builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.emit(I64ExtendI32S);
					});
					from([I64], builder -> builder.emit(I64Load(WasmLayout.DYN_PAYLOAD_OFFSET)));
					from([F64], function(builder) {
						builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.emit(I32TruncF64S);
						builder.emit(I64ExtendI32S);
					});
				default:
					// Bool storage keeps HashLink's normalized truth value.
					from([I32, Bool], function(builder) {
						builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.localSet(valueType);
						isOneOf(builder, elementType, [Bool]);
						builder.ifElse(function(builder) {
							builder.localGet(valueType);
							builder.i32Eqz();
							builder.i32Eqz();
						}, builder -> builder.localGet(valueType), I32);
					});
					from([F64], function(builder) {
						builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.emit(I32TruncF64S);
					});
					from([I64], function(builder) {
						builder.emit(I64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.emit(I32WrapI64);
					});
			}
			raiseCast(builder, value, elementType);
			return module.addFunction(builder.finish());
		});
	}

	/** Push the encoded value for the storage kind selected by `byStorage`. */
	function pushEncoded(builder:WasmFunctionBuilder, kind:WasmValueType, reference:Bool, array:WasmLocalRef, value:WasmLocalRef):Void {
		builder.localGet(array);
		builder.localGet(value);
		builder.call(builder.functionRef(encode(kind, reference)));
	}

	/** Dispatch a call to the concrete operation for the array's storage, passing its encoded value. */
	function dispatchEncoded(builder:WasmFunctionBuilder, operation:String, array:WasmLocalRef, before:Array<WasmLocalRef>, value:WasmLocalRef,
			elementType:WasmLocalRef, ?result:WasmValueType):Void {
		function call(kind:WasmValueType, reference:Bool, suffix:String):WasmFunctionBuilder->Void
			return function(builder) {
				var encoded = builder.local('encoded_$suffix', kind);
				pushEncoded(builder, kind, reference, array, value);
				builder.localSet(encoded);
				builder.localGet(array);
				for (local in before)
					builder.localGet(local);
				builder.localGet(encoded);
				builder.call(builder.functionRef(concrete('__array_${operation}_$suffix')));
			};
		byStorage(builder, elementType, call(I32, false, "i32"), call(F64, false, "f64"), call(I64, false, "i64"), call(I32, true, "ref"), result);
	}

	/** Call the stride-compatible concrete operation; element bytes are copied without interpretation. */
	function dispatchStride(builder:WasmFunctionBuilder, operation:String, array:WasmLocalRef, pushArguments:WasmFunctionBuilder->Void,
			?result:WasmValueType):Void {
		var strideOf = stride();
		builder.localGet(array);
		builder.call(builder.functionRef(strideOf));
		builder.i32Const(8);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			pushArguments(builder);
			builder.call(builder.functionRef(concrete('__array_${operation}_f64')));
		}, function(builder) {
			pushArguments(builder);
			builder.call(builder.functionRef(concrete('__array_${operation}_i32')));
		}, result);
	}

	// Natives.

	function addAllocTypedRef(name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			length = builder.parameter("length", 0),
			elementType = builder.parameter("elementType", 1),
			array = builder.local("array", I32);
		builder.localGet(length);
		builder.call(builder.functionRef(concrete("__array_alloc_ref")));
		builder.localTee(array);
		builder.localGet(elementType);
		builder.emit(I32Store(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET));
		builder.localGet(array);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	/** Concrete array views require exact storage; dynamic storage is retyped on the first view. */
	function addCheckCast(name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			array = builder.parameter("array", 0),
			target = builder.parameter("target", 1),
			elementType = builder.local("elementType", I32);
		builder.localGet(array);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.return_();
		});
		loadElementType(builder, array);
		builder.localTee(elementType);
		builder.localGet(target);
		builder.emit(I32Eq);
		isOneOf(builder, target, [Dyn]);
		builder.emit(I32Or);
		builder.if_(function(builder) {
			builder.localGet(array);
			builder.return_();
		});
		isOneOf(builder, elementType, [Dyn]);
		builder.if_(function(builder) {
			builder.localGet(array);
			builder.localGet(target);
			builder.call(builder.functionRef(retype()));
			builder.localGet(array);
			builder.return_();
		});
		concatenate(builder, [
			literal("Array element type mismatch: "),
			typeNameOf(elementType),
			literal(" -> "),
			typeNameOf(target)
		]);
		raise(builder);
		return module.addFunction(builder.finish());
	}

	/**
	 * Give dynamic storage its first concrete element type (`realtime_array_retype`). Every element
	 * is validated before the array changes; primitive storage is converted into a new block.
	 */
	function retype():Int
		return helper("__haxeon_array_retype", function(name) {
			var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: []}),
				array = builder.parameter("array", 0),
				target = builder.parameter("target", 1),
				length = builder.local("length", I32),
				index = builder.local("index", I32),
				value = builder.local("value", I32),
				source = builder.local("source", I32),
				data = builder.local("data", I32),
				capacity = builder.local("capacity", I32),
				targetStride = builder.local("targetStride", I32),
				valueType = builder.local("valueType", I32),
				slot = builder.local("slot", I32),
				check = accepts(),
				digits = intToString(),
				allocator = context.allocatorFunction;
			function forEachElement(builder:WasmFunctionBuilder, body:WasmFunctionBuilder->Void):Void {
				builder.i32Const(0);
				builder.localSet(index);
				builder.block(function(builder) {
					builder.loop(function(builder) {
						builder.localGet(index);
						builder.localGet(length);
						builder.emit(I32LtS);
						builder.i32Eqz();
						builder.emit(BrIf(1));
						builder.localGet(source);
						builder.localGet(index);
						builder.i32Const(4);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.emit(I32Load(0));
						builder.localSet(value);
						body(builder);
						builder.localGet(index);
						builder.i32Const(1);
						builder.i32Add();
						builder.localSet(index);
						builder.emit(Br(0));
					});
				});
			}
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
			builder.localSet(length);
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localSet(source);
			forEachElement(builder, function(builder) {
				builder.localGet(target);
				builder.localGet(value);
				builder.call(builder.functionRef(check));
				builder.i32Eqz();
				builder.if_(function(builder) {
					var indexText = function(builder:WasmFunctionBuilder) {
						builder.localGet(index);
						builder.call(builder.functionRef(digits));
					};
					concatenate(builder, [
						literal("Array element type mismatch: "),
						literal("Dynamic"),
						literal(" -> "),
						typeNameOf(target),
						literal(" (element "),
						indexText,
						literal(" is "),
						valueTypeNameOf(value),
						literal(")")
					]);
					raise(builder);
				});
			});
			isOneOf(builder, target, [I32, Bool, F64, I64]);
			builder.if_(function(builder) {
				isOneOf(builder, target, [F64, I64]);
				builder.ifElse(function(builder) builder.i32Const(8), function(builder) builder.i32Const(4), I32);
				builder.localSet(targetStride);
				builder.localGet(array);
				builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
				builder.localTee(capacity);
				builder.i32Eqz();
				builder.if_(function(builder) {
					builder.i32Const(1);
					builder.localSet(capacity);
				});
				builder.localGet(capacity);
				builder.localGet(targetStride);
				builder.emit(I32Mul);
				builder.call(builder.functionRef(allocator));
				builder.localSet(data);
				// Primitive storage holds no references: record the owner and stop scanning it.
				builder.localGet(data);
				builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE - WasmLayout.GC_BLOCK_LINK_OFFSET);
				builder.i32Sub();
				builder.localGet(array);
				builder.emit(I32Store(0));
				builder.localGet(data);
				builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE - WasmLayout.GC_BLOCK_FLAGS_OFFSET);
				builder.i32Sub();
				builder.localGet(data);
				builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE - WasmLayout.GC_BLOCK_FLAGS_OFFSET);
				builder.i32Sub();
				builder.emit(I32Load(0));
				builder.i32Const(WasmLayout.GC_BLOCK_CLEAR_SCAN_MASK);
				builder.emit(I32And);
				builder.emit(I32Store(0));
				forEachElement(builder, function(builder) {
					// Validation admitted only null-free numeric boxes for primitive storage.
					builder.localGet(value);
					builder.emit(I32Load(0));
					builder.localSet(valueType);
					builder.localGet(data);
					builder.localGet(index);
					builder.localGet(targetStride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.localSet(slot);
					// Unbox the payload that the value's own type holds, converted for the target storage.
					function payload(builder:WasmFunctionBuilder, type:IrType, convert:Array<WasmInstruction>):Void {
						builder.localGet(value);
						builder.emit(type == F64 ? F64Load(WasmLayout.DYN_PAYLOAD_OFFSET) : type == I64 ? I64Load(WasmLayout.DYN_PAYLOAD_OFFSET) : I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.emitAll(convert);
					}
					isOneOf(builder, target, [F64]);
					builder.ifElse(function(builder) {
						builder.localGet(slot);
						isOneOf(builder, valueType, [F64]);
						builder.ifElse(builder -> payload(builder, F64, []), function(builder) {
							isOneOf(builder, valueType, [I64]);
							builder.ifElse(builder -> payload(builder, I64, [F64ConvertI64S]), builder -> payload(builder, I32, [F64ConvertI32S]), F64);
						}, F64);
						builder.emit(F64Store(0));
					}, function(builder) {
						isOneOf(builder, target, [I64]);
						builder.ifElse(function(builder) {
							builder.localGet(slot);
							isOneOf(builder, valueType, [I64]);
							builder.ifElse(builder -> payload(builder, I64, []), builder -> payload(builder, I32, [I64ExtendI32S]), I64);
							builder.emit(I64Store(0));
						}, function(builder) {
							builder.localGet(slot);
							isOneOf(builder, valueType, [I64]);
							builder.ifElse(builder -> payload(builder, I64, [I32WrapI64]), builder -> payload(builder, I32, []), I32);
							builder.emit(I32Store(0));
						});
					});
				});
				builder.localGet(array);
				builder.localGet(data);
				builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
				builder.localGet(array);
				builder.localGet(capacity);
				builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
			});
			builder.localGet(array);
			builder.localGet(target);
			builder.emit(I32Store(WasmLayout.ARRAY_ELEMENT_TYPE_OFFSET));
			return module.addFunction(builder.finish());
		});

	function addGet(name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			array = builder.parameter("array", 0),
			index = builder.parameter("index", 1);
		builder.localGet(index);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.localGet(index);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.emit(I32LtS);
		builder.i32Eqz();
		builder.emit(I32Or);
		builder.if_(function(builder) {
			builder.i32Const(string("Array index out of bounds"));
			raise(builder);
		});
		builder.localGet(array);
		builder.localGet(index);
		builder.call(builder.functionRef(box()));
		builder.return_();
		return module.addFunction(builder.finish());
	}

	/** Write through the storage element type, converting before the array grows. */
	function addSet(name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: []}),
			array = builder.parameter("array", 0),
			index = builder.parameter("index", 1),
			value = builder.parameter("value", 2),
			elementType = builder.local("elementType", I32),
			encodedI32 = builder.local("encodedI32", I32),
			encodedF64 = builder.local("encodedF64", F64),
			encodedI64 = builder.local("encodedI64", I64),
			strideLocal = builder.local("stride", I32),
			slot = builder.local("slot", I32);
		loadElementType(builder, array);
		builder.localSet(elementType);
		function encodeInto(kind:WasmValueType, reference:Bool, target:WasmLocalRef):WasmFunctionBuilder->Void
			return function(builder) {
				pushEncoded(builder, kind, reference, array, value);
				builder.localSet(target);
			};
		byStorage(builder, elementType, encodeInto(I32, false, encodedI32), encodeInto(F64, false, encodedF64), encodeInto(I64, false, encodedI64),
			encodeInto(I32, true, encodedI32));
		builder.localGet(index);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) {
			builder.i32Const(string("Array index out of bounds"));
			raise(builder);
		});
		builder.localGet(index);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.emit(I32LtS);
		builder.i32Eqz();
		builder.if_(function(builder) {
			dispatchStride(builder, "resize", array, function(builder) {
				builder.localGet(array);
				builder.localGet(index);
				builder.i32Const(1);
				builder.i32Add();
			});
		});
		builder.localGet(array);
		builder.call(builder.functionRef(stride()));
		builder.localSet(strideLocal);
		slotAddress(builder, array, index, strideLocal);
		builder.localSet(slot);
		function store(local:WasmLocalRef, instruction:WasmInstruction):WasmFunctionBuilder->Void
			return function(builder) {
				builder.localGet(slot);
				builder.localGet(local);
				builder.emit(instruction);
			};
		byStorage(builder, elementType, store(encodedI32, I32Store(0)), store(encodedF64, F64Store(0)), store(encodedI64, I64Store(0)),
			store(encodedI32, I32Store(0)));
		return module.addFunction(builder.finish());
	}

	/** push, unshift and insert: encode for the storage, then run the concrete operation. */
	function addValueOperation(name:String, operation:String, positioned:Bool):Int {
		var parameters:Array<WasmValueType> = positioned ? [I32, I32, I32] : [I32, I32],
			results:Array<WasmValueType> = positioned ? [] : [I32],
			builder = new WasmFunctionBuilder(name,
				{
					parameters: parameters,
					results: results
				}),
			array = builder.parameter("array", 0),
			position = positioned ? builder.parameter("position", 1) : null,
			value = builder.parameter("value", positioned ? 2 : 1),
			elementType = builder.local("elementType", I32);
		loadElementType(builder, array);
		builder.localSet(elementType);
		dispatchEncoded(builder, operation, array, positioned ? [position] : [], value, elementType, positioned ? null : I32);
		if (!positioned)
			builder.return_();
		return module.addFunction(builder.finish());
	}

	/** pop and shift: box the removed element, then remove it with the stride-compatible operation. */
	function addTake(name:String, operation:String, first:Bool):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			array = builder.parameter("array", 0),
			length = builder.local("length", I32),
			index = builder.local("index", I32),
			value = builder.local("value", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localTee(length);
		builder.i32Const(0);
		builder.emit(I32LeS);
		builder.if_(function(builder) {
			builder.i32Const(string(first ? "Array.shift on an empty array" : "Array.pop on an empty array"));
			raise(builder);
		});
		if (first)
			builder.i32Const(0);
		else {
			builder.localGet(length);
			builder.i32Const(1);
			builder.i32Sub();
		}
		builder.localSet(index);
		builder.localGet(array);
		builder.localGet(index);
		builder.call(builder.functionRef(box()));
		builder.localSet(value);
		// f64 and i32 variants move eight- and four-byte slots respectively; the result is dropped.
		var strideOf = stride();
		builder.localGet(array);
		builder.call(builder.functionRef(strideOf));
		builder.i32Const(8);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			builder.localGet(array);
			builder.call(builder.functionRef(concrete('__array_${operation}_f64')));
			builder.emit(Drop);
		}, function(builder) {
			builder.localGet(array);
			builder.call(builder.functionRef(concrete('__array_${operation}_i32')));
			builder.emit(Drop);
		});
		builder.localGet(value);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	/** Dynamic equality: identity first, then value equality for boxed numbers and strings. */
	function indexOf():Int {
		var existing = context.functions.get("__array_index_of_any");
		if (existing != null)
			return existing;
		var index = helper("__array_index_of_any", function(name) {
			var builder = new WasmFunctionBuilder(name,
				{parameters: [I32, I32], results: [I32]}), array = builder.parameter("array",
					0), searched = builder.parameter("searched",
					1), index = builder.local("index", I32), element = builder.local("element", I32), read = box(), equal = dynamicEqual();
			builder.i32Const(0);
			builder.localSet(index);
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(index);
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
					builder.emit(I32LtS);
					builder.i32Eqz();
					builder.emit(BrIf(1));
					builder.localGet(array);
					builder.localGet(index);
					builder.call(builder.functionRef(read));
					builder.localTee(element);
					builder.localGet(searched);
					builder.emit(I32Eq);
					builder.localGet(element);
					builder.localGet(searched);
					builder.call(builder.functionRef(equal));
					builder.emit(I32Or);
					builder.if_(function(builder) {
						builder.localGet(index);
						builder.return_();
					});
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(0));
				});
			});
			builder.i32Const(-1);
			builder.return_();
			return module.addFunction(builder.finish());
		});
		context.functions.set("__array_index_of_any", index);
		return index;
	}

	function addRemove(name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			array = builder.parameter("array", 0),
			searched = builder.parameter("searched", 1),
			index = builder.local("index", I32),
			length = builder.local("length", I32),
			strideLocal = builder.local("stride", I32);
		builder.localGet(array);
		builder.localGet(searched);
		builder.call(builder.functionRef(indexOf()));
		builder.localTee(index);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.return_();
		});
		builder.localGet(array);
		builder.call(builder.functionRef(stride()));
		builder.localSet(strideLocal);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.i32Const(1);
		builder.i32Sub();
		builder.localSet(length);
		slotAddress(builder, array, index, strideLocal);
		builder.localGet(index);
		builder.i32Const(1);
		builder.i32Add();
		builder.localSet(index);
		slotAddress(builder, array, index, strideLocal);
		builder.localGet(length);
		builder.localGet(index);
		builder.i32Sub();
		builder.i32Const(1);
		builder.i32Add();
		builder.localGet(strideLocal);
		builder.emit(I32Mul);
		builder.emit(MemoryCopy);
		builder.localGet(array);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		slotAddress(builder, array, length, strideLocal);
		builder.i32Const(0);
		builder.localGet(strideLocal);
		builder.emit(MemoryFill);
		builder.i32Const(1);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	/** Mixed storage concatenates into dynamic storage; equal storage keeps its element type. */
	function addConcat(name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}), left = builder.parameter("left", 0),
			right = builder.parameter("right", 1), leftLength = builder.local("leftLength", I32), result = builder.local("result", I32),
			index = builder.local("index", I32), boxed = builder.local("boxed", I32), read = box();
		loadElementType(builder, left);
		loadElementType(builder, right);
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			dispatchStride(builder, "concat", left, function(builder) {
				builder.localGet(left);
				builder.localGet(right);
			}, I32);
			builder.return_();
		});
		builder.localGet(left);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localTee(leftLength);
		builder.localGet(right);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.i32Add();
		builder.call(builder.functionRef(concrete("__array_alloc_ref")));
		builder.localSet(result);
		function copyFrom(source:WasmLocalRef, offset:Null<WasmLocalRef>):Void {
			builder.i32Const(0);
			builder.localSet(index);
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(index);
					builder.localGet(source);
					builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
					builder.emit(I32LtS);
					builder.i32Eqz();
					builder.emit(BrIf(1));
					builder.localGet(source);
					builder.localGet(index);
					builder.call(builder.functionRef(read));
					builder.localSet(boxed);
					builder.localGet(result);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(index);
					if (offset != null) {
						builder.localGet(offset);
						builder.i32Add();
					}
					builder.i32Const(4);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.localGet(boxed);
					builder.emit(I32Store(0));
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(0));
				});
			});
		}
		copyFrom(left, null);
		copyFrom(right, leftLength);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	/** copy, slice, splice and reverse move element bytes, so the stride-compatible operation serves. */
	function addStorageOperation(name:String, operation:String, parameters:Array<WasmValueType>, results:Array<WasmValueType>):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: parameters, results: results}),
			locals = [for (index in 0...parameters.length) builder.parameter('argument_$index', index)];
		dispatchStride(builder, operation, locals[0], function(builder) {
			for (local in locals)
				builder.localGet(local);
		}, results.length == 0 ? null : results[0]);
		if (results.length != 0)
			builder.return_();
		return module.addFunction(builder.finish());
	}

	function addResize(name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: []}),
			array = builder.parameter("array", 0),
			length = builder.parameter("length", 1);
		builder.localGet(length);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) {
			builder.i32Const(string("Array.resize length must be non-negative"));
			raise(builder);
		});
		dispatchStride(builder, "resize", array, function(builder) {
			builder.localGet(array);
			builder.localGet(length);
		});
		return module.addFunction(builder.finish());
	}
}
