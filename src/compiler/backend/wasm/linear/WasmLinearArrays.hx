package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrType;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
import compiler.backend.wasm.WasmBackend;

class WasmLinearArrays {
	public static function registerNativeAllocators(context:WasmLinearContext):Void {
		for (native in context.program.natives) {
			var stride = arrayStrideForNative(native.name);
			if (stride != null)
				context.functions.set(native.name, addArrayAllocator(context.module, native.name, stride, context.allocatorFunction));
		}
	}

	public static function addArrayCopy(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			source = builder.parameter("source", 0),
			sourceLength = builder.local("sourceLength", I32),
			copy = builder.local("copy", I32),
			data = builder.local("data", I32),
			capacity = builder.local("capacity", I32);
		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(sourceLength);
		builder.i32Const(WasmLayout.ARRAY_HEADER_SIZE);
		builder.call(builder.functionRef(allocator));
		builder.localSet(copy);
		builder.localGet(copy);
		builder.i32Const(WasmModuleSupport.typeId(Array(Dyn)));
		builder.emit(I32Store(0));
		builder.localGet(copy);
		builder.localGet(sourceLength);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localGet(copy);
		builder.localGet(sourceLength);
		builder.i32Const(8);
		builder.i32Add();
		builder.localTee(capacity);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(capacity);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.call(builder.functionRef(allocator));
		builder.localSet(data);
		builder.localGet(data);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Sub();
		builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
		builder.i32Add();
		builder.localGet(copy);
		builder.emit(I32Store(0));
		builder.localGet(copy);
		builder.localGet(data);
		builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(data);
		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(sourceLength);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.emit(MemoryCopy);
		builder.localGet(copy);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayJoinBytes(module:WasmModule, name:String, allocator:Int, stringConcat:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			values = builder.parameter("values", 0),
			separator = builder.parameter("separator", 1),
			result = builder.local("result", I32),
			index = builder.local("index", I32);
		builder.local("unused_4", I32);
		builder.local("unused_5", I32);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.i32Const(0);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.i32Const(0);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.i32Const(0);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(values);
				builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(index);
					builder.i32Eqz();
					builder.ifElse(function(_) {}, function(builder) {
						builder.localGet(result);
						builder.localGet(separator);
						builder.call(builder.functionRef(stringConcat));
						builder.localSet(result);
					});
					builder.localGet(result);
					builder.localGet(values);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(index);
					builder.i32Const(4);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(I32Load(0));
					builder.call(builder.functionRef(stringConcat));
					builder.localSet(result);
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(0)));
			});
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayIndexOf(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, stringEqual:Null<Int>):Int {
		var stringEqualFunction:Int = stringEqual == null ? -1 : cast stringEqual,
			compare:WasmInstruction = elementType == F64 ? F64Eq : I32Eq;
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, elementType], results: [I32]}),
			array = builder.parameter("array", 0),
			searched = builder.parameter("searched", 1),
			index = builder.local("index", I32),
			foundIndex = builder.local("foundIndex", I32);
		builder.i32Const(0);
		builder.localSet(index);
		builder.i32Const(-1);
		builder.localSet(foundIndex);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(array);
				builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(index);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
					builder.localGet(searched);
					builder.emit(stringEqualFunction < 0 ? compare : Call(stringEqualFunction));
					builder.if_(function(builder) {
						builder.localGet(index);
						builder.localSet(foundIndex);
						builder.emit(Br(3));
					});
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(1));
				}, function(_) {});
			});
		});
		builder.localGet(foundIndex);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArraySlice(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: [I32]}),
			source = builder.parameter("source", 0),
			startIndex = builder.parameter("startIndex", 1),
			endIndex = builder.parameter("endIndex", 2),
			sourceLength = builder.local("sourceLength", I32),
			start = builder.local("start", I32),
			end = builder.local("end", I32),
			length = builder.local("length", I32),
			result = builder.local("result", I32),
			data = builder.local("data", I32);
		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(sourceLength);
		builder.localGet(startIndex);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.localGet(sourceLength);
			builder.localGet(startIndex);
			builder.i32Add();
			builder.localSet(start);
		}, function(builder) {
			builder.localGet(startIndex);
			builder.localSet(start);
		});
		builder.localGet(start);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.localSet(start);
		});
		builder.localGet(start);
		builder.localGet(sourceLength);
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(sourceLength);
			builder.localSet(start);
		});
		builder.localGet(endIndex);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.localGet(sourceLength);
			builder.localGet(endIndex);
			builder.i32Add();
			builder.localSet(end);
		}, function(builder) {
			builder.localGet(endIndex);
			builder.localSet(end);
		});
		builder.localGet(end);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.localSet(end);
		});
		builder.localGet(end);
		builder.localGet(sourceLength);
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(sourceLength);
			builder.localSet(end);
		});
		builder.localGet(end);
		builder.localGet(start);
		builder.emit(I32LtS);
		builder.if_(function(builder) {
			builder.localGet(start);
			builder.localSet(end);
		});
		builder.localGet(end);
		builder.localGet(start);
		builder.i32Sub();
		builder.localSet(length);
		builder.i32Const(WasmLayout.ARRAY_HEADER_SIZE);
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Array(Dyn)));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.i32Const(8);
		builder.i32Add();
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(length);
		builder.i32Const(8);
		builder.i32Add();
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.call(builder.functionRef(allocator));
		builder.localSet(data);
		builder.localGet(data);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Sub();
		builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
		builder.i32Add();
		builder.localGet(result);
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(data);
		builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(data);
		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(start);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(length);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.emit(MemoryCopy);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayConcat(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32], results: [I32]}, [for (_ in 0...4) {type: I32}], [
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
			I32Const(WasmModuleSupport.typeId(Array(Dyn))),
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
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(4),
			I32Store(0),
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

	public static function addArrayPush(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, elementType], results: [I32]}),
			array = builder.parameter("array", 0),
			value = builder.parameter("value", 1),
			length = builder.local("length", I32),
			capacity = builder.local("capacity", I32),
			data = builder.local("data", I32),
			newLength = builder.local("newLength", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(length);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.localTee(capacity);
			builder.i32Eqz();
			builder.ifElse(function(builder) {
				builder.i32Const(8);
				builder.localSet(capacity);
			}, function(builder) {
				builder.localGet(capacity);
				builder.i32Const(2);
				builder.emit(I32Mul);
				builder.localSet(capacity);
			});
			builder.localGet(capacity);
			builder.i32Const(stride);
			builder.emit(I32Mul);
			builder.call(builder.functionRef(allocator));
			builder.localSet(data);
			builder.localGet(data);
			builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
			builder.i32Sub();
			builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
			builder.i32Add();
			builder.localGet(array);
			builder.emit(I32Store(0));
			builder.localGet(data);
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(length);
			builder.i32Const(stride);
			builder.emit(I32Mul);
			builder.emit(MemoryCopy);
			builder.localGet(array);
			builder.localGet(data);
			builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(array);
			builder.localGet(capacity);
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		});
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(length);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(value);
		builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
		builder.localGet(array);
		builder.localGet(length);
		builder.i32Const(1);
		builder.i32Add();
		builder.localTee(newLength);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localGet(newLength);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayPop(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [elementType]}),
			array = builder.parameter("array", 0),
			length = builder.local("length", I32),
			index = builder.local("index", I32),
			value = builder.local("value", elementType);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.i32Const(0);
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.localGet(length);
			builder.i32Const(1);
			builder.i32Sub();
			builder.localSet(index);
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(index);
			builder.i32Const(stride);
			builder.emit(I32Mul);
			builder.i32Add();
			builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
			builder.localSet(value);
			builder.localGet(array);
			builder.localGet(index);
			builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		}, function(builder) builder.emit(Unreachable));
		builder.localGet(value);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayUnshift(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, elementType], results: [I32]}),
			array = builder.parameter("array", 0),
			value = builder.parameter("value", 1),
			length = builder.local("length", I32),
			index = builder.local("index", I32),
			capacity = builder.local("capacity", I32),
			data = builder.local("data", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(length);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.localTee(capacity);
			builder.i32Eqz();
			builder.ifElse(function(builder) {
				builder.i32Const(8);
				builder.localSet(capacity);
			}, function(builder) {
				builder.localGet(capacity);
				builder.i32Const(2);
				builder.emit(I32Mul);
				builder.localSet(capacity);
			});
			builder.localGet(capacity);
			builder.i32Const(stride);
			builder.emit(I32Mul);
			builder.call(builder.functionRef(allocator));
			builder.localSet(data);
			builder.localGet(data);
			builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
			builder.i32Sub();
			builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
			builder.i32Add();
			builder.localGet(array);
			builder.emit(I32Store(0));
			builder.localGet(data);
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(length);
			builder.i32Const(stride);
			builder.emit(I32Mul);
			builder.emit(MemoryCopy);
			builder.localGet(array);
			builder.localGet(data);
			builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(array);
			builder.localGet(capacity);
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		});
		builder.localGet(length);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.i32Const(0);
				builder.localGet(index);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Sub();
					builder.localSet(index);
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(index);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
					builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(value);
		builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
		builder.localGet(array);
		builder.localGet(length);
		builder.i32Const(1);
		builder.i32Add();
		builder.localTee(index);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localGet(index);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayInsert(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, elementType], results: []}),
			array = builder.parameter("array", 0),
			requestedIndex = builder.parameter("requestedIndex", 1),
			value = builder.parameter("value", 2),
			length = builder.local("length", I32),
			index = builder.local("index", I32),
			cursor = builder.local("cursor", I32),
			capacity = builder.local("capacity", I32),
			data = builder.local("data", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(requestedIndex);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.i32Const(0);
			builder.localSet(index);
		}, function(builder) {
			builder.localGet(requestedIndex);
			builder.localSet(index);
		});
		builder.localGet(index);
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(length);
			builder.localSet(index);
		});
		builder.localGet(length);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.localTee(capacity);
			builder.i32Eqz();
			builder.ifElse(function(builder) {
				builder.i32Const(8);
				builder.localSet(capacity);
			}, function(builder) {
				builder.localGet(capacity);
				builder.i32Const(2);
				builder.emit(I32Mul);
				builder.localSet(capacity);
			});
			builder.localGet(capacity);
			builder.i32Const(stride);
			builder.emit(I32Mul);
			builder.call(builder.functionRef(allocator));
			builder.localSet(data);
			builder.localGet(data);
			builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
			builder.i32Sub();
			builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
			builder.i32Add();
			builder.localGet(array);
			builder.emit(I32Store(0));
			builder.localGet(data);
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(length);
			builder.i32Const(stride);
			builder.emit(I32Mul);
			builder.emit(MemoryCopy);
			builder.localGet(array);
			builder.localGet(data);
			builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(array);
			builder.localGet(capacity);
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		});
		builder.localGet(length);
		builder.localSet(cursor);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(cursor);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(cursor);
					builder.i32Const(1);
					builder.i32Sub();
					builder.localSet(cursor);
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(cursor);
					builder.i32Const(1);
					builder.i32Add();
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(cursor);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
					builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(index);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(value);
		builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
		builder.localGet(array);
		builder.localGet(length);
		builder.i32Const(1);
		builder.i32Add();
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		return module.addFunction(builder.finish());
	}

	public static function addArrayShift(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [elementType]}),
			array = builder.parameter("array", 0),
			length = builder.local("length", I32),
			value = builder.local("value", elementType),
			index = builder.local("index", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.i32Const(0);
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
			builder.localSet(value);
			builder.i32Const(1);
			builder.localSet(index);
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(index);
					builder.localGet(length);
					builder.emit(I32LtS);
					builder.ifElse(function(builder) {
						builder.localGet(array);
						builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
						builder.localGet(index);
						builder.i32Const(1);
						builder.i32Sub();
						builder.i32Const(stride);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.localGet(array);
						builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
						builder.localGet(index);
						builder.i32Const(stride);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
						builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
						builder.localGet(index);
						builder.i32Const(1);
						builder.i32Add();
						builder.localSet(index);
						builder.emit(Br(1));
					}, function(builder) builder.emit(Br(2)));
				});
			});
			builder.localGet(array);
			builder.localGet(length);
			builder.i32Const(1);
			builder.i32Sub();
			builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		}, function(builder) builder.emit(Unreachable));
		builder.localGet(value);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayResize(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: []}),
			array = builder.parameter("array", 0),
			newLength = builder.parameter("newLength", 1),
			length = builder.local("length", I32),
			cursor = builder.local("cursor", I32),
			newCapacity = builder.local("newCapacity", I32),
			newData = builder.local("newData", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(newLength);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.emit(Unreachable);
		}, function(builder) {
			builder.localGet(newLength);
			builder.localGet(array);
			builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.emit(I32LeS);
			builder.ifElse(function(builder) {
				builder.localGet(length);
				builder.localSet(cursor);
				builder.block(function(builder) {
					builder.loop(function(builder) {
						builder.localGet(cursor);
						builder.localGet(newLength);
						builder.emit(I32LtS);
						builder.ifElse(function(builder) {
							builder.localGet(array);
							builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
							builder.localGet(cursor);
							builder.i32Const(stride);
							builder.emit(I32Mul);
							builder.i32Add();
							builder.emit(elementType == F64 ? F64Const(0.0) : I32Const(0));
							builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
							builder.localGet(cursor);
							builder.i32Const(1);
							builder.i32Add();
							builder.localSet(cursor);
							builder.emit(Br(1));
						}, function(builder) builder.emit(Br(2)));
					});
				});
				builder.localGet(array);
				builder.localGet(newLength);
				builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
			}, function(builder) {
				builder.localGet(array);
				builder.emit(I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET));
				builder.i32Const(2);
				builder.emit(I32Mul);
				builder.localSet(newCapacity);
				builder.localGet(newCapacity);
				builder.localGet(newLength);
				builder.emit(I32LtS);
				builder.if_(function(builder) {
					builder.localGet(newLength);
					builder.localSet(newCapacity);
				});
				builder.localGet(newCapacity);
				builder.i32Const(stride);
				builder.emit(I32Mul);
				builder.call(builder.functionRef(allocator));
				builder.localSet(newData);
				builder.localGet(newData);
				builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
				builder.i32Sub();
				builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
				builder.i32Add();
				builder.localGet(array);
				builder.emit(I32Store(0));
				builder.localGet(newData);
				builder.localGet(array);
				builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
				builder.localGet(length);
				builder.i32Const(stride);
				builder.emit(I32Mul);
				builder.emit(MemoryCopy);
				builder.localGet(array);
				builder.localGet(newData);
				builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
				builder.localGet(array);
				builder.localGet(newCapacity);
				builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
			});
		});
		return module.addFunction(builder.finish());
	}

	public static function addArrayRemove(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, stringEqual:Null<Int>):Int {
		var stringEqualFunction:Int = stringEqual == null ? -1 : cast stringEqual,
			compare:WasmInstruction = elementType == F64 ? F64Eq : I32Eq,
			builder = new WasmFunctionBuilder(name,
				{
					parameters: [I32, elementType],
					results: [I32]
				}),
			array = builder.parameter("array", 0),
			searched = builder.parameter("searched", 1),
			length = builder.local("length", I32),
			index = builder.local("index", I32),
			foundIndex = builder.local("foundIndex", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.i32Const(0);
		builder.localSet(index);
		builder.i32Const(-1);
		builder.localSet(foundIndex);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(length);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(index);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
					builder.localGet(searched);
					builder.emit(stringEqualFunction < 0 ? compare : Call(stringEqualFunction));
					builder.if_(function(builder) {
						builder.localGet(index);
						builder.localSet(foundIndex);
						builder.emit(Br(3));
					});
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
		builder.i32Const(-1);
		builder.localGet(foundIndex);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.localGet(foundIndex);
			builder.i32Const(1);
			builder.i32Add();
			builder.localSet(index);
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(index);
					builder.localGet(length);
					builder.emit(I32LtS);
					builder.ifElse(function(builder) {
						builder.localGet(array);
						builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
						builder.localGet(index);
						builder.i32Const(1);
						builder.i32Sub();
						builder.i32Const(stride);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.localGet(array);
						builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
						builder.localGet(index);
						builder.i32Const(stride);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
						builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
						builder.localGet(index);
						builder.i32Const(1);
						builder.i32Add();
						builder.localSet(index);
						builder.emit(Br(1));
					}, function(builder) builder.emit(Br(2)));
				});
			});
			builder.localGet(array);
			builder.localGet(length);
			builder.i32Const(1);
			builder.i32Sub();
			builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
			builder.i32Const(1);
			builder.localSet(foundIndex);
		}, function(builder) {
			builder.i32Const(0);
			builder.localSet(foundIndex);
		});
		builder.localGet(foundIndex);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayReverse(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: []}),
			array = builder.parameter("array", 0),
			length = builder.local("length", I32),
			left = builder.local("left", I32),
			right = builder.local("right", I32),
			temporary = builder.local("temporary", elementType);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.i32Const(0);
		builder.localSet(left);
		builder.localGet(length);
		builder.i32Const(1);
		builder.i32Sub();
		builder.localSet(right);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(left);
				builder.localGet(right);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(left);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
					builder.localSet(temporary);
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(left);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(right);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(elementType == F64 ? F64Load(0) : I32Load(0));
					builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(right);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.localGet(temporary);
					builder.emit(elementType == F64 ? F64Store(0) : I32Store(0));
					builder.localGet(left);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(left);
					builder.localGet(right);
					builder.i32Const(1);
					builder.i32Sub();
					builder.localSet(right);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
		return module.addFunction(builder.finish());
	}

	public static function addArraySplice(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: [I32]}),
			array = builder.parameter("array", 0),
			requestedStart = builder.parameter("requestedStart", 1),
			requestedDeleteCount = builder.parameter("requestedDeleteCount", 2),
			length = builder.local("length", I32),
			start = builder.local("start", I32),
			deleteCount = builder.local("deleteCount", I32),
			removed = builder.local("removed", I32),
			tailLength = builder.local("tailLength", I32),
			removedData = builder.local("removedData", I32);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(requestedStart);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.localGet(length);
			builder.localGet(requestedStart);
			builder.i32Add();
			builder.localSet(start);
		}, function(builder) {
			builder.localGet(requestedStart);
			builder.localSet(start);
		});
		builder.localGet(start);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.localSet(start);
		});
		builder.localGet(start);
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(length);
			builder.localSet(start);
		});
		builder.localGet(requestedDeleteCount);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.i32Const(0);
			builder.localSet(deleteCount);
		}, function(builder) {
			builder.localGet(requestedDeleteCount);
			builder.localSet(deleteCount);
		});
		builder.localGet(deleteCount);
		builder.localGet(length);
		builder.localGet(start);
		builder.i32Sub();
		builder.emit(I32LtS);
		builder.ifElse(function(_) {}, function(builder) {
			builder.localGet(length);
			builder.localGet(start);
			builder.i32Sub();
			builder.localSet(deleteCount);
		});
		builder.i32Const(WasmLayout.ARRAY_HEADER_SIZE);
		builder.call(builder.functionRef(allocator));
		builder.localSet(removed);
		builder.localGet(removed);
		builder.i32Const(WasmModuleSupport.typeId(Array(Dyn)));
		builder.emit(I32Store(0));
		builder.localGet(removed);
		builder.localGet(deleteCount);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localGet(removed);
		builder.localGet(deleteCount);
		builder.i32Const(8);
		builder.i32Add();
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(deleteCount);
		builder.i32Const(8);
		builder.i32Add();
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.call(builder.functionRef(allocator));
		builder.localSet(removedData);
		builder.localGet(removedData);
		builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
		builder.i32Sub();
		builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
		builder.i32Add();
		builder.localGet(removed);
		builder.emit(I32Store(0));
		builder.localGet(removed);
		builder.localGet(removedData);
		builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(removedData);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(start);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(deleteCount);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.emit(MemoryCopy);
		builder.localGet(length);
		builder.localGet(start);
		builder.i32Sub();
		builder.localGet(deleteCount);
		builder.i32Sub();
		builder.localSet(tailLength);
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(start);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(array);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localGet(start);
		builder.localGet(deleteCount);
		builder.i32Add();
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(tailLength);
		builder.i32Const(stride);
		builder.emit(I32Mul);
		builder.emit(MemoryCopy);
		builder.localGet(array);
		builder.localGet(length);
		builder.localGet(deleteCount);
		builder.i32Sub();
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localGet(removed);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	public static function addArrayAllocator(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		var type:WasmFunctionType = {parameters: [I32], results: [I32]};
		var body:Array<WasmInstruction> = [
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(WasmModuleSupport.typeId(Array(Dyn))),
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
			LocalSet(3)
		];
		if (name == "__array_alloc_i32" || name == "__array_alloc_bool" || name == "__array_alloc_f64")
			body = body.concat([
				LocalGet(3),
				I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
				I32Sub,
				I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
				I32Add,
				LocalGet(3),
				I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
				I32Sub,
				I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
				I32Add,
				I32Load(0),
				I32Const(WasmLayout.GC_BLOCK_CLEAR_SCAN_MASK),
				I32And,
				I32Store(0)
			]);
		else
			WasmLinearGc.appendGcContainerOwner(body, 3, 1);
		body = body.concat([
			LocalGet(1),
			LocalGet(3),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(1),
			Return
		]);
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, type, [{type: I32}, {type: I32}, {type: I32}], body));
	}

	public static function arrayStrideForNative(name:String):Null<Int>
		return switch name {
			case "__array_alloc_f64": 8;
			case "__array_alloc_i32", "__array_alloc_bool", "__array_alloc_ref", "__array_alloc_bytes": 4;
			default: null;
		};
}
