package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** A function-local index. It remains a lightweight abstract over Wasm's integer index. */
abstract WasmLocalRef(Int) from Int to Int {
	public inline function new(index:Int)
		this = index;
}

/** A module-global index. It remains a lightweight abstract over Wasm's integer index. */
abstract WasmGlobalRef(Int) from Int to Int {
	public inline function new(index:Int)
		this = index;
}

/** A function index. It remains a lightweight abstract over Wasm's integer index. */
abstract WasmFunctionRef(Int) from Int to Int {
	public inline function new(index:Int)
		this = index;
}

/** Direct authoring support for WasmInstruction arrays; no intermediate representation is built. */
class WasmFunctionBuilder {
	public final name:String;
	public final type:WasmFunctionType;
	public final locals:Array<WasmLocal> = [];
	public final body:Array<WasmInstruction> = [];

	final localNames:Map<String, WasmLocalRef> = [];

	public function new(name:String, type:WasmFunctionType) {
		this.name = name;
		this.type = type;
	}

	/** Reserve a module function index before its body is complete. */
	public function register(module:WasmModule):WasmFunctionRef
		return new WasmFunctionRef(module.addFunction(new WasmFunction(name, type)));

	/** Adopt a legacy raw instruction body while still allocating locals through the builder. */
	public static function fromRaw(name:String, type:WasmFunctionType, ?locals:Array<WasmLocal>, ?body:Array<WasmInstruction>):WasmFunction {
		var builder = new WasmFunctionBuilder(name, type);
		if (locals != null)
			for (index in 0...locals.length)
				builder.local('local_$index', locals[index].type);
		if (body != null)
			builder.emitAll(body);
		return builder.finish();
	}

	/** Return the completed function using the exact instruction sequence emitted so far. */
	public function finish():WasmFunction
		return new WasmFunction(name, type, locals.copy(), body.copy());

	/** Name a parameter, whose index precedes the builder-owned locals. */
	public function parameter(name:String, index:Int):WasmLocalRef {
		if (index < 0 || index >= type.parameters.length)
			throw 'Parameter index $index is outside function ${this.name}';
		return rememberLocal(name, new WasmLocalRef(index));
	}

	/** Allocate one function local and return its absolute Wasm local index. */
	public function local(name:String, type:WasmValueType):WasmLocalRef {
		var index = this.type.parameters.length + locals.length;
		locals.push({type: type});
		return rememberLocal(name, new WasmLocalRef(index));
	}

	function rememberLocal(name:String, local:WasmLocalRef):WasmLocalRef {
		if (localNames.exists(name))
			throw 'Duplicate local name "$name" in ${this.name}';
		localNames.set(name, local);
		return local;
	}

	public inline function global(index:Int):WasmGlobalRef
		return new WasmGlobalRef(index);

	public inline function functionRef(index:Int):WasmFunctionRef
		return new WasmFunctionRef(index);

	public inline function emitAll(instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			emit(instruction);

	/** Unrestricted escape hatch for every instruction in the target vocabulary. */
	public inline function emit(instruction:WasmInstruction):Void
		body.push(instruction);

	public inline function localGet(local:WasmLocalRef):Void
		emit(LocalGet(local));

	public inline function localSet(local:WasmLocalRef):Void
		emit(LocalSet(local));

	public inline function localTee(local:WasmLocalRef):Void
		emit(LocalTee(local));

	public inline function globalGet(global:WasmGlobalRef):Void
		emit(GlobalGet(global));

	public inline function globalSet(global:WasmGlobalRef):Void
		emit(GlobalSet(global));

	public inline function i32Const(value:Int):Void
		emit(I32Const(value));

	public inline function i32Add():Void
		emit(I32Add);

	public inline function i32Sub():Void
		emit(I32Sub);

	public inline function i32Eqz():Void
		emit(I32Eqz);

	public inline function call(functionRef:WasmFunctionRef):Void
		emit(Call(functionRef));

	public inline function return_():Void
		emit(Return);
}
