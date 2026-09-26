package compiler.backend.wasm.gc;

import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.WasmTypes.WasmRefType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/**
 * Exact array storage with `Array<Dynamic>` views for Wasm GC, ported from `native/runtime/arrays.c`.
 *
 * Every array shares one wrapper struct whose data field holds element-typed storage and whose
 * element-type field records the storage element type. Dynamic operations dispatch on that field
 * and reuse the concrete lowering for the selected storage, boxing on read and checking or
 * unboxing on write. Dynamic storage takes its element type on the first concrete view
 * (`__array_check_cast`): every element is validated before new storage replaces the old one.
 */
class WasmGcDynamicArrays {
	public static final OPERATIONS = [
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

	final plan:WasmGcTypePlan;
	final program:IrProgram;
	final representation:WasmGcRepresentation;
	final elements:Array<IrType>;
	final throws:Bool;
	final locals:Array<WasmLocal> = [];
	final body:Array<WasmInstruction> = [];
	var nextLocal:Int;

	public static function isOperation(name:String):Bool
		return OPERATIONS.indexOf(name) >= 0;

	/** Emit a module function for each dynamic-view native the program uses. */
	public static function register(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, representation:WasmGcRepresentation,
			program:IrProgram, used:Map<String, Bool>):Void {
		for (native in program.natives)
			if (used.exists(native.name) && isOperation(native.name) && !functions.exists(native.name))
				functions.set(native.name, new WasmGcDynamicArrays(plan, program, representation, native).emit(module, native));
	}

	function new(plan:WasmGcTypePlan, program:IrProgram, gcRepresentation:WasmGcRepresentation, native:IrNative) {
		this.plan = plan;
		this.program = program;
		elements = plan.arrayElementTypes();
		throws = WasmModuleSupport.hasExceptions(program);
		nextLocal = native.arguments.length;
		representation = gcRepresentation.forFunction({allocateLocal: allocateLocal, exceptionTag: throws ? 0 : null, irFunction: null});
	}

	function allocateLocal(type:WasmValueType):Int {
		locals.push({type: type});
		return nextLocal++;
	}

	function emit(module:WasmModule, native:IrNative):Int {
		var result = native.result == Void ? -1 : allocateLocal(plan.valueType(native.result));
		switch native.name {
			case "__array_alloc_typed_ref":
				allocTypedRef(0, 1, result);
			case "__array_check_cast":
				checkCast(0, 1, result);
			case "__array_get_any":
				get(0, 1, result);
			case "__array_set_any":
				set(0, 1, 2);
			case "__array_push_any":
				valueOperation("push", 0, [], 1, result);
			case "__array_unshift_any":
				valueOperation("unshift", 0, [], 1, result);
			case "__array_insert_any":
				valueOperation("insert", 0, [1], 2, result);
			case "__array_pop_any":
				take("pop", "Array.pop on an empty array", 0, result);
			case "__array_shift_any":
				take("shift", "Array.shift on an empty array", 0, result);
			case "__array_index_of_any":
				indexOf(0, 1, result);
			case "__array_remove_any":
				remove(0, 1, result);
			case "__array_concat_any":
				concat(0, 1, result);
			case "__array_copy_any":
				storageOperation("copy", 0, [], Array(Dyn), result);
			case "__array_slice_any":
				storageOperation("slice", 0, [1, 2], Array(Dyn), result);
			case "__array_splice_any":
				storageOperation("splice", 0, [1, 2], Array(Dyn), result);
			case "__array_reverse_any":
				storageOperation("reverse", 0, [], Void, result);
			case "__array_resize_any":
				resize(0, 1);
			default:
				throw 'Unknown Wasm GC dynamic array operation "${native.name}"';
		}
		if (result >= 0)
			body.push(LocalGet(result));
		body.push(Return);
		return module.addFunction(new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), locals, body));
	}

	// Emission helpers.

	inline function push(instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function handled(result:WasmLoweringResult):Array<WasmInstruction>
		return switch result {
			case Handled(instructions): instructions;
			case UseDefault: throw "Wasm GC representation declined a dynamic array operation";
		};

	static inline function typeId(type:IrType):Int
		return WasmModuleSupport.typeId(type);

	static function value(type:IrType):IrValue
		return new IrValue(-1, "dynamic-array-operand", type);

	function wrapper():Int
		return plan.arrayType(Dyn);

	function storageReference(element:IrType):WasmValueType
		return Ref(plan.arrayStorageReference(element));

	function loadField(array:Int, field:Int):Array<WasmInstruction>
		return [LocalGet(array), StructGet(wrapper(), field)];

	function loadStorage(array:Int, element:IrType):Array<WasmInstruction>
		return loadField(array, WasmGcTypePlan.arrayDataFieldIndex()).concat([RefCast(plan.arrayStorageReference(element))]);

	function elementType(array:Int):Int {
		var local = allocateLocal(I32);
		push(loadField(array, WasmGcTypePlan.arrayElementTypeFieldIndex()));
		body.push(LocalSet(local));
		return local;
	}

	/** Branch on a runtime element type id: one arm per element type with planned storage. */
	function dispatch(typeLocal:Int, arm:IrType->Void, ?except:IrType):Void {
		var opened = 0;
		for (element in elements) {
			if (except != null && typeId(element) == typeId(except))
				continue;
			push([LocalGet(typeLocal), I32Const(typeId(element)), I32Eq, If(null)]);
			arm(element);
			body.push(Else);
			opened++;
		}
		// Every array is created with one of the planned storage types.
		body.push(Unreachable);
		for (_ in 0...opened)
			body.push(End);
	}

	/** Counted loop over `0 ... length`; `index` holds the position inside `each`. */
	function forEach(index:Int, length:Int, each:Void->Void):Void {
		push([
			I32Const(0),
			LocalSet(index),
			Block(null),
			Loop(null),
			LocalGet(index),
			LocalGet(length),
			I32LtS,
			I32Eqz,
			BrIf(1)
		]);
		each();
		push([LocalGet(index), I32Const(1), I32Add, LocalSet(index), Br(0), End, End]);
	}

	function lower(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>):Void
		push(handled(representation.lowerRuntimeCall(name, output, arguments, outputLocal, argumentLocals)));

	function concrete(operation:String, element:IrType):String
		return '__array_${operation}_${WasmGcRepresentation.arrayNativeSuffix(element)}';

	// Diagnostics.

	function literal(text:String):Int {
		var local = allocateLocal(plan.valueType(Bytes));
		push(handled(representation.constantString(text, local, [])));
		return local;
	}

	function concatenate(parts:Array<Int>):Int {
		var result = parts[0];
		for (index in 1...parts.length) {
			var joined = allocateLocal(plan.valueType(Bytes));
			lower("__string_concat", value(Bytes), [value(Bytes), value(Bytes)], joined, [result, parts[index]]);
			result = joined;
		}
		return result;
	}

	/** Throw the message as a Haxe exception, or trap when the program cannot catch one. */
	function raise(message:Int):Void
		push(throws ? [LocalGet(message), Throw(0)] : [Unreachable]);

	function raiseText(text:String):Void
		raise(literal(text));

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

	/** Name of the element type a runtime type id denotes. */
	function typeName(typeLocal:Int):Int {
		var result = allocateLocal(plan.valueType(Bytes)),
			named:Array<IrType> = [I32, I64, F64, Bool, Bytes, Dyn],
			seen:Map<Int, Bool> = [for (type in named) typeId(type) => true];
		for (element in elements)
			if (!seen.exists(typeId(element))) {
				seen.set(typeId(element), true);
				named.push(element);
			}
		push(handled(representation.constantString("Object", result, [])));
		for (type in named) {
			push([LocalGet(typeLocal), I32Const(typeId(type)), I32Eq, If(null)]);
			push(handled(representation.constantString(staticTypeName(type), result, [])));
			body.push(End);
		}
		return result;
	}

	/** Name of a dynamic value's runtime type. */
	function valueTypeName(valueLocal:Int):Int {
		var result = allocateLocal(plan.valueType(Bytes));
		function when(test:Array<WasmInstruction>, name:String):Void {
			push([LocalGet(valueLocal)].concat(test).concat([If(null)]));
			push(handled(representation.constantString(name, result, [])));
			body.push(End);
		}
		push(handled(representation.constantString("Object", result, [])));
		// Later matches win, so derived classes are tested after their bases.
		for (object in objectsBaseFirst())
			if (plan.objectTypeIndices.exists(object))
				when([RefTest({nullable: false, heap: Type(plan.objectType(object))})], object);
		for (enumDecl in program.enums)
			if (plan.enumTypeIndices.exists(enumDecl.name))
				when([RefTest({nullable: false, heap: Type(plan.enumType(enumDecl.name))})], enumDecl.name);
		if (elements.length != 0)
			when([RefTest({nullable: false, heap: Type(wrapper())})], "Array");
		when([RefTest({nullable: false, heap: Type(plan.bytesTypeIndex)})], "String");
		for (type in ([I32, Bool, I64, F64] : Array<IrType>))
			when([RefTest({nullable: false, heap: Type(plan.boxedPrimitiveType(type))})], staticTypeName(type));
		when([RefIsNull], "null");
		return result;
	}

	function objectsBaseFirst():Array<String> {
		var depth:Map<String, Int> = [], bases:Map<String, Null<String>> = [];
		for (object in program.objects)
			bases.set(object.name, object.base);
		function depthOf(name:String):Int {
			var base = bases.get(name);
			return base == null || !bases.exists(base) ? 0 : depthOf(base) + 1;
		}
		var names = [for (object in program.objects) object.name];
		for (name in names)
			depth.set(name, depthOf(name));
		names.sort((left, right) -> depth.get(left) - depth.get(right));
		return names;
	}

	function raiseCast(valueLocal:Int, typeLocal:Int):Void
		raise(concatenate([
			literal("Can't cast "),
			valueTypeName(valueLocal),
			literal(" to "),
			typeName(typeLocal)
		]));

	// Conversions between dynamic values and element storage.

	/** Dynamic, structural and abstract storage holds anyref and converts every value unchecked. */
	static function isAnyReference(reference:WasmRefType):Bool
		return switch reference.heap {
			case compiler.backend.wasm.WasmTypes.WasmHeapType.Any: true;
			default: false;
		};

	/** Push the payload of a boxed primitive, converted to the element's Wasm value type. */
	function unboxAs(valueLocal:Int, box:IrType, element:IrType):Array<WasmInstruction> {
		var boxType = plan.boxedPrimitiveType(box),
			load:Array<WasmInstruction> = [
				LocalGet(valueLocal),
				RefCast({nullable: false, heap: Type(boxType)}),
				StructGet(boxType, 0)
			];
		var target = plan.valueType(element), source = plan.valueType(box);
		var convert:Array<WasmInstruction> = switch [source, target] {
			case [I32, I32]: element == Bool ? [I32Eqz, I32Eqz] : [];
			case [I64, I32]: [I32WrapI64];
			case [F64, I32]: [I32TruncF64S];
			case [I32, I64]: [I64ExtendI32S];
			case [I64, I64]: [];
			case [F64, I64]: [I32TruncF64S, I64ExtendI32S];
			case [I32, F64]: [F64ConvertI32S];
			case [I64, F64]: [F64ConvertI64S];
			case [F64, F64]: [];
			default: throw 'Unsupported Wasm GC dynamic array conversion from $box to $element';
		};
		return load.concat(convert);
	}

	function isBox(valueLocal:Int, box:IrType):Array<WasmInstruction>
		return [
			LocalGet(valueLocal),
			RefTest({nullable: false, heap: Type(plan.boxedPrimitiveType(box))})
		];

	/**
	 * Convert a dynamic value for storage of `element` (`realtime_any_encode`): primitive storage
	 * unboxes numbers as a dynamic cast would, reference storage checks the value's runtime type.
	 */
	function encode(element:IrType, valueLocal:Int, typeLocal:Int):Int {
		var target = plan.valueType(element), result = allocateLocal(target);
		switch target {
			case Ref(reference) if (isAnyReference(reference)):
				push([LocalGet(valueLocal), LocalSet(result)]);
			case Ref(reference):
				push([
					LocalGet(valueLocal),
					RefIsNull,
					If(null),
					RefNull(reference.heap),
					LocalSet(result),
					Else
				]);
				push([LocalGet(valueLocal), RefTest({nullable: false, heap: reference.heap}), If(null)]);
				push([LocalGet(valueLocal), RefCast(reference), LocalSet(result), Else]);
				raiseCast(valueLocal, typeLocal);
				push([End, End]);
			default:
				push([LocalGet(valueLocal), RefIsNull, If(null)]);
				push(representation.zeroValue(element));
				push([LocalSet(result), Else]);
				var opened = 0;
				for (box in ([I32, Bool, I64, F64] : Array<IrType>)) {
					push(isBox(valueLocal, box).concat([If(null)]));
					push(unboxAs(valueLocal, box, element));
					push([LocalSet(result), Else]);
					opened++;
				}
				raiseCast(valueLocal, typeLocal);
				for (_ in 0...opened)
					body.push(End);
				body.push(End);
		}
		return result;
	}

	/**
	 * True when a dynamic value converts to `element` without changing its meaning
	 * (`realtime_array_accepts`): Int storage never truncates a Float, only Bool fills Bool storage.
	 */
	function accepts(element:IrType, valueLocal:Int, result:Int):Void {
		switch plan.valueType(element) {
			case Ref(reference) if (isAnyReference(reference)):
				push([I32Const(1), LocalSet(result)]);
			case Ref(reference):
				push([
					LocalGet(valueLocal),
					RefIsNull,
					LocalGet(valueLocal),
					RefTest({nullable: false, heap: reference.heap}),
					I32Or,
					LocalSet(result)
				]);
			default:
				var boxes:Array<IrType> = switch element {
					case Bool: [Bool];
					case F64, F32: [I32, I64, F64];
					default: [I32, I64];
				};
				push([I32Const(0), LocalSet(result)]);
				for (box in boxes)
					push(isBox(valueLocal, box).concat([LocalGet(result), I32Or, LocalSet(result)]));
		}
	}

	/** Box a stored element as a dynamic value (`realtime_any_read`). */
	function box(element:IrType, elementLocal:Int):Int {
		var result = allocateLocal(plan.valueType(Dyn));
		push(handled(representation.toDynamic(value(element), result, elementLocal)));
		return result;
	}

	/** Read element `index` of `element` storage and box it. */
	function read(element:IrType, array:Int, index:Int):Int {
		var stored = allocateLocal(plan.valueType(element));
		push(loadStorage(array, element).concat([LocalGet(index), ArrayGet(plan.arrayStorageType(element)), LocalSet(stored)]));
		return box(element, stored);
	}

	// Natives.

	function allocTypedRef(length:Int, elementTypeLocal:Int, result:Int):Void
		dispatch(elementTypeLocal, function(element) {
			push([
				LocalGet(length),
				LocalGet(length),
				I32Const(8),
				I32Add,
				ArrayNewDefault(plan.arrayStorageType(element)),
				LocalGet(elementTypeLocal),
				StructNew(wrapper()),
				LocalSet(result)
			]);
		});

	/** Concrete array views require exact storage; dynamic storage is retyped on the first view. */
	function checkCast(array:Int, target:Int, result:Int):Void {
		push([LocalGet(array), LocalSet(result), LocalGet(array), RefIsNull, I32Eqz, If(null)]);
		var current = elementType(array);
		push([
			LocalGet(current),
			LocalGet(target),
			I32Eq,
			LocalGet(target),
			I32Const(typeId(Dyn)),
			I32Eq,
			I32Or,
			I32Eqz,
			If(null)
		]);
		push([LocalGet(current), I32Const(typeId(Dyn)), I32Eq, If(null)]);
		retype(array, target);
		body.push(Else);
		raise(concatenate([
			literal("Array element type mismatch: "),
			typeName(current),
			literal(" -> "),
			typeName(target)
		]));
		push([End, End, End]);
	}

	/**
	 * Give dynamic storage its first concrete element type (`realtime_array_retype`). Every element
	 * is validated before the array changes, then converted into new storage of the same capacity.
	 */
	function retype(array:Int, target:Int):Void {
		var length = allocateLocal(I32),
			index = allocateLocal(I32),
			valueLocal = allocateLocal(plan.valueType(Dyn)),
			ok = allocateLocal(I32),
			source = allocateLocal(storageReference(Dyn)),
			dynamicStorage = plan.arrayStorageType(Dyn);
		push(loadField(array, WasmGcTypePlan.arrayLengthFieldIndex()).concat([LocalSet(length)]));
		push(loadStorage(array, Dyn).concat([LocalSet(source)]));
		function eachValue(each:Void->Void):Void
			forEach(index, length, function() {
				push([
					LocalGet(source),
					LocalGet(index),
					ArrayGet(dynamicStorage),
					LocalSet(valueLocal)
				]);
				each();
			});
		dispatch(target, function(element) {
			var storageType = plan.arrayStorageType(element),
				converted = allocateLocal(storageReference(element));
			eachValue(function() {
				accepts(element, valueLocal, ok);
				push([LocalGet(ok), I32Eqz, If(null)]);
				var indexText = allocateLocal(plan.valueType(Bytes)),
					boxedIndex = allocateLocal(plan.valueType(Dyn));
				push(handled(representation.toDynamic(value(I32), boxedIndex, index)));
				lower("__std_string", value(Bytes), [value(Dyn)], indexText, [boxedIndex]);
				raise(concatenate([
					literal("Array element type mismatch: Dynamic -> "),
					typeName(target),
					literal(" (element "),
					indexText,
					literal(" is "),
					valueTypeName(valueLocal),
					literal(")")
				]));
				body.push(End);
			});
			push([LocalGet(source), ArrayLen, ArrayNewDefault(storageType), LocalSet(converted)]);
			eachValue(function() {
				var encoded = encode(element, valueLocal, target);
				push([LocalGet(converted), LocalGet(index), LocalGet(encoded), ArraySet(storageType)]);
			});
			push([
				LocalGet(array),
				LocalGet(converted),
				StructSet(wrapper(), WasmGcTypePlan.arrayDataFieldIndex()),
				LocalGet(array),
				LocalGet(target),
				StructSet(wrapper(), WasmGcTypePlan.arrayElementTypeFieldIndex())
			]);
		}, Dyn);
	}

	function checkIndex(array:Int, index:Int):Void {
		push([LocalGet(index), I32Const(0), I32LtS, LocalGet(index)]);
		push(loadField(array, WasmGcTypePlan.arrayLengthFieldIndex()));
		push([I32LtS, I32Eqz, I32Or, If(null)]);
		raiseText("Array index out of bounds");
		body.push(End);
	}

	function get(array:Int, index:Int, result:Int):Void {
		checkIndex(array, index);
		var current = elementType(array);
		dispatch(current, function(element) push([LocalGet(read(element, array, index)), LocalSet(result)]));
	}

	/** Write through the storage element type, converting before the array grows. */
	function set(array:Int, index:Int, valueLocal:Int):Void {
		var current = elementType(array);
		dispatch(current, function(element) {
			var encoded = encode(element, valueLocal, current);
			push(handled(representation.arraySet(value(Array(element)), value(I32), value(element), array, index, encoded)));
		});
	}

	/** push, unshift and insert: encode for the storage, then run the concrete operation. */
	function valueOperation(operation:String, array:Int, extra:Array<Int>, valueLocal:Int, result:Int):Void {
		var current = elementType(array);
		dispatch(current, function(element) {
			var encoded = encode(element, valueLocal, current),
				arguments = [value(Array(element))].concat([for (_ in extra) value(I32)]).concat([value(element)]);
			lower(concrete(operation, element), value(result >= 0 ? I32 : Void), arguments, result, [array].concat(extra).concat([encoded]));
		});
	}

	/** pop and shift: box the removed element returned by the concrete operation. */
	function take(operation:String, emptyMessage:String, array:Int, result:Int):Void {
		push(loadField(array, WasmGcTypePlan.arrayLengthFieldIndex()).concat([I32Const(0), I32LeS, If(null)]));
		raiseText(emptyMessage);
		body.push(End);
		var current = elementType(array);
		dispatch(current, function(element) {
			var taken = allocateLocal(plan.valueType(element));
			lower(concrete(operation, element), value(element), [value(Array(element))], taken, [array]);
			push([LocalGet(box(element, taken)), LocalSet(result)]);
		});
	}

	/** Dynamic equality: identity first, then value equality for boxed numbers and strings. */
	function findIndex(array:Int, searched:Int, result:Int):Void {
		var length = allocateLocal(I32),
			index = allocateLocal(I32),
			equal = allocateLocal(I32),
			current = elementType(array);
		push(loadField(array, WasmGcTypePlan.arrayLengthFieldIndex()).concat([LocalSet(length), I32Const(-1), LocalSet(result)]));
		dispatch(current, function(element) {
			push([Block(null)]);
			forEach(index, length, function() {
				var boxed = read(element, array, index);
				push(handled(representation.dynamicEqual(equal, boxed, searched)));
				push([LocalGet(equal), If(null), LocalGet(index), LocalSet(result), Br(3), End]);
			});
			body.push(End);
		});
	}

	function indexOf(array:Int, searched:Int, result:Int):Void
		findIndex(array, searched, result);

	function remove(array:Int, searched:Int, result:Int):Void {
		var index = allocateLocal(I32), one = allocateLocal(I32);
		findIndex(array, searched, index);
		push([
			I32Const(0),
			LocalSet(result),
			LocalGet(index),
			I32Const(0),
			I32LtS,
			I32Eqz,
			If(null),
			I32Const(1),
			LocalSet(one)
		]);
		var current = elementType(array);
		dispatch(current, function(element) {
			var removed = allocateLocal(plan.valueType(Array(element)));
			lower(concrete("splice", element), value(Array(element)), [value(Array(element)), value(I32), value(I32)], removed, [array, index, one]);
		});
		push([I32Const(1), LocalSet(result), End]);
	}

	/** Mixed storage concatenates into dynamic storage; equal storage keeps its element type. */
	function concat(left:Int, right:Int, result:Int):Void {
		var leftType = elementType(left),
			rightType = elementType(right),
			total = allocateLocal(I32),
			offset = allocateLocal(I32),
			index = allocateLocal(I32),
			length = allocateLocal(I32);
		push([LocalGet(leftType), LocalGet(rightType), I32Eq, If(null)]);
		dispatch(leftType, function(element) {
			lower(concrete("concat", element), value(Array(element)), [value(Array(element)), value(Array(element))], result, [left, right]);
		});
		body.push(Else);
		push(loadField(left, WasmGcTypePlan.arrayLengthFieldIndex()));
		push(loadField(right, WasmGcTypePlan.arrayLengthFieldIndex()));
		push([I32Add, LocalSet(total)]);
		lower("__array_alloc_ref", value(Array(Dyn)), [value(I32)], result, [total]);
		for (source in [
			{array: left, type: leftType, first: true},
			{array: right, type: rightType, first: false}
		]) {
			if (source.first)
				push([I32Const(0), LocalSet(offset)]);
			push(loadField(source.array, WasmGcTypePlan.arrayLengthFieldIndex()).concat([LocalSet(length)]));
			dispatch(source.type, function(element) {
				forEach(index, length, function() {
					var boxed = read(element, source.array, index);
					push(loadStorage(result, Dyn));
					push([
						LocalGet(index),
						LocalGet(offset),
						I32Add,
						LocalGet(boxed),
						ArraySet(plan.arrayStorageType(Dyn))
					]);
				});
			});
			push([LocalGet(length), LocalSet(offset)]);
		}
		body.push(End);
	}

	/** copy, slice, splice and reverse operate on storage without converting elements. */
	function storageOperation(operation:String, array:Int, extra:Array<Int>, resultType:IrType, result:Int):Void {
		var current = elementType(array);
		dispatch(current, function(element) {
			var output = resultType == Void ? Void : Array(element);
			lower(concrete(operation, element), value(output), [value(Array(element))].concat([for (_ in extra) value(I32)]), result, [array].concat(extra));
		});
	}

	function resize(array:Int, length:Int):Void {
		push([LocalGet(length), I32Const(0), I32LtS, If(null)]);
		raiseText("Array.resize length must be non-negative");
		body.push(End);
		var current = elementType(array);
		dispatch(current, function(element) {
			lower(concrete("resize", element), value(Void), [value(Array(element)), value(I32)], -1, [array, length]);
		});
	}
}
