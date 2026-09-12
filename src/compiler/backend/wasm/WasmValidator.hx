package compiler.backend.wasm;

import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmGlobal;

private typedef WasmControl = {
	final kind:Int;
	final result:Null<WasmValueType>;
	final height:Int;
}

/** Target-level structural validation before bytes reach an embedding runtime. */
class WasmValidator {
	public static function validate(module:WasmModule):Void {
		for (fn in module.functions)
			validateFunction(fn, [for (index in 0...module.functionCount()) module.functionType(index)], module.globals, module.types, module.tableMin,
				module.exceptionTagType);
		for (entry in module.exports)
			if (entry.functionIndex < 0 || entry.functionIndex >= module.functionCount())
				throw 'Wasm export "${entry.name}" references function ${entry.functionIndex}';
		if (module.start != null) {
			if (module.start < 0 || module.start >= module.functionCount())
				throw 'Wasm start references function ${module.start}';
			var startType = module.functionType(module.start);
			if (startType.parameters.length != 0 || startType.results.length != 0)
				throw 'Wasm start function must have no parameters or results';
		}
	}

	static function validateFunction(fn:WasmFunction, functions:Array<WasmFunctionType>, globals:Array<WasmGlobal>, types:Array<WasmFunctionType>,
			tableMin:Null<Int>, tagType:Null<Int>):Void {
		var labels:Array<Bool> = [],
			localCount = fn.type.parameters.length + fn.locals.length;
		for (instruction in fn.body) {
			switch instruction {
				case Block(_), Loop(_), Try(_):
					labels.push(false);
				case If(_):
					labels.push(true);
				case Else:
					if (labels.length == 0 || !labels[labels.length - 1])
						throw 'Wasm function ${fn.name} has an else without an if';
				case Catch(tag):
					if (tagType == null)
						throw 'Wasm function ${fn.name} references an invalid exception tag $tag';
				case End:
					if (labels.length == 0)
						throw 'Wasm function ${fn.name} has an unmatched end';
					labels.pop();
				case Br(depth), BrIf(depth):
					if (depth < 0 || depth >= labels.length)
						throw 'Wasm function ${fn.name} has an invalid branch depth $depth';
				case BrTable(targets, defaultDepth):
					for (depth in targets)
						validateDepth(fn, depth, labels.length);
					validateDepth(fn, defaultDepth, labels.length);
				case LocalGet(index), LocalSet(index), LocalTee(index):
					if (index < 0 || index >= localCount)
						throw 'Wasm function ${fn.name} references invalid local $index';
				case Call(index):
					if (index < 0 || index >= functions.length)
						throw 'Wasm function ${fn.name} references invalid function $index';
				case CallIndirect(typeIndex):
					if (tableMin == null)
						throw 'Wasm function ${fn.name} uses call_indirect without a table';
					if (typeIndex < 0 || typeIndex >= types.length)
						throw 'Wasm function ${fn.name} references invalid indirect type $typeIndex';
				case GlobalGet(index), GlobalSet(index):
					if (index < 0 || index >= globals.length)
						throw 'Wasm function ${fn.name} references invalid global $index';
				default:
			}
		}
		if (labels.length != 0)
			throw 'Wasm function ${fn.name} has ${labels.length} unclosed control blocks';
		validateStack(fn, functions, globals, types, tagType);
	}

	static function validateStack(fn:WasmFunction, functions:Array<WasmFunctionType>, globals:Array<WasmGlobal>, types:Array<WasmFunctionType>,
			tagType:Null<Int>):Void {
		var locals:Array<WasmValueType> = fn.type.parameters.copy();
		for (local in fn.locals)
			locals.push(local.type);
		var stack:Array<WasmValueType> = [],
			controls:Array<WasmControl> = [],
			reachable = true;
		for (instruction in fn.body) {
			switch instruction {
				case Unreachable:
					reachable = false;
				case Block(result):
					controls.push({kind: 0, result: result, height: stack.length});
				case Loop(result):
					controls.push({kind: 1, result: result, height: stack.length});
				case Try(result):
					controls.push({kind: 3, result: result, height: stack.length});
				case If(result):
					pop(stack, I32, fn);
					controls.push({kind: 2, result: result, height: stack.length});
				case Else:
					if (controls.length == 0 || controls[controls.length - 1].kind != 2)
						throw 'Wasm function ${fn.name} has an invalid else frame';
					var frame = controls[controls.length - 1];
					reset(stack, frame.height, frame.result, reachable, fn);
					reachable = true;
				case Catch(tag):
					if (tagType == null)
						throw 'Wasm function ${fn.name} references an invalid exception tag $tag';
					if (controls.length == 0 || controls[controls.length - 1].kind != 3)
						throw 'Wasm function ${fn.name} has a catch without a try';
					var catchFrame = controls[controls.length - 1];
					reset(stack, catchFrame.height, catchFrame.result, reachable, fn);
					stack.push(I32);
					reachable = true;
				case End:
					if (controls.length == 0)
						continue;
					var frame = controls.pop();
					reset(stack, frame.height, frame.result, reachable, fn);
					reachable = true;
				case Br(depth):
					validateBranch(controls, depth, fn);
					reachable = false;
				case BrIf(depth):
					pop(stack, I32, fn);
					validateBranch(controls, depth, fn);
				case BrTable(targets, defaultDepth):
					pop(stack, I32, fn);
					for (depth in targets)
						validateBranch(controls, depth, fn);
					validateBranch(controls, defaultDepth, fn);
					reachable = false;
				case Return:
					for (index in 0...fn.type.results.length)
						pop(stack, fn.type.results[fn.type.results.length - index - 1], fn);
					reachable = false;
				case Throw(tag):
					if (tagType == null)
						throw 'Wasm function ${fn.name} references an invalid exception tag $tag';
					pop(stack, I32, fn);
					reachable = false;
				case Call(index):
					var type = functions[index];
					for (index in 0...type.parameters.length)
						pop(stack, type.parameters[type.parameters.length - index - 1], fn);
					for (result in type.results)
						stack.push(result);
				case CallIndirect(typeIndex):
					var type = types[typeIndex];
					pop(stack, I32, fn);
					for (index in 0...type.parameters.length)
						pop(stack, type.parameters[type.parameters.length - index - 1], fn);
					for (result in type.results)
						stack.push(result);
				case Drop:
					if (reachable)
						popAny(stack, fn);
				case MemoryCopy:
					if (reachable) {
						pop(stack, I32, fn);
						pop(stack, I32, fn);
						pop(stack, I32, fn);
					}
				case MemorySize:
					if (reachable)
						stack.push(I32);
				case MemoryGrow:
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(I32);
					}
				case LocalGet(index):
					if (reachable)
						stack.push(locals[index]);
				case LocalSet(index):
					if (reachable) {
						var actual = popAny(stack, fn);
						if (actual != locals[index])
							throw 'Wasm function ${fn.name} local $index expects ${locals[index]}, got $actual';
					}
				case LocalTee(index):
					if (reachable) {
						pop(stack, locals[index], fn);
						stack.push(locals[index]);
					}
				case GlobalGet(index):
					if (reachable)
						stack.push(globals[index].type);
				case GlobalSet(index):
					if (reachable)
						pop(stack, globals[index].type, fn);
				case I32Load(_), I32Load8S(_), I32Load8U(_), I32Load16S(_), I32Load16U(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(I32);
					}
				case I64Load(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(I64);
					}
				case F32Load(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(F32);
					}
				case F64Load(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(F64);
					}
				case I32Store(_), I32Store8(_), I32Store16(_):
					if (reachable) {
						pop(stack, I32, fn);
						pop(stack, I32, fn);
					}
				case I64Store(_):
					if (reachable) {
						pop(stack, I64, fn);
						pop(stack, I32, fn);
					}
				case F32Store(_):
					if (reachable) {
						pop(stack, F32, fn);
						pop(stack, I32, fn);
					}
				case F64Store(_):
					if (reachable) {
						pop(stack, F64, fn);
						pop(stack, I32, fn);
					}
				case I32Const(_):
					if (reachable)
						stack.push(I32);
				case I64Const(_):
					if (reachable)
						stack.push(I64);
				case F64Const(_):
					if (reachable)
						stack.push(F64);
				case I32Add, I32Sub, I32Mul, I32DivS, I32RemS, I32And, I32Xor, I32Or, I32Shl, I32ShrS, I32ShrU, I32Eq, I32LtS, I32LeS:
					binary(stack, I32, I32, fn);
				case I64Add, I64Sub, I64Mul, I64DivS, I64RemS, I64And, I64Xor, I64Or, I64Shl, I64ShrS, I64ShrU:
					binary(stack, I64, I64, fn);
				case I64Eq, I64LtS, I64LeS:
					binary(stack, I64, I32, fn);
				case F64Add, F64Sub, F64Mul, F64Div:
					binary(stack, F64, F64, fn);
				case F64Eq, F64Lt, F64Le:
					binary(stack, F64, I32, fn);
				case I32Eqz:
					pop(stack, I32, fn);
					if (reachable)
						stack.push(I32);
				case I64Eqz:
					pop(stack, I64, fn);
					if (reachable)
						stack.push(I32);
				case F64ConvertI32S:
					pop(stack, I32, fn);
					if (reachable)
						stack.push(F64);
				case F64ConvertI64S:
					pop(stack, I64, fn);
					if (reachable)
						stack.push(F64);
				case I64ExtendI32S:
					pop(stack, I32, fn);
					if (reachable)
						stack.push(I64);
				case F64PromoteF32:
					pop(stack, F32, fn);
					if (reachable)
						stack.push(F64);
				case F32DemoteF64:
					pop(stack, F64, fn);
					if (reachable)
						stack.push(F32);
				case I32WrapI64:
					pop(stack, I64, fn);
					if (reachable)
						stack.push(I32);
				case I32TruncF64S:
					pop(stack, F64, fn);
					if (reachable)
						stack.push(I32);
				case Nop:
			}
		}
		if (controls.length != 0)
			throw 'Wasm function ${fn.name} has unclosed stack control frames';
	}

	static function binary(stack:Array<WasmValueType>, input:WasmValueType, output:WasmValueType, fn:WasmFunction):Void {
		pop(stack, input, fn);
		pop(stack, input, fn);
		stack.push(output);
	}

	static function pop(stack:Array<WasmValueType>, expected:WasmValueType, fn:WasmFunction):Void {
		var actual = popAny(stack, fn);
		if (actual != expected)
			throw 'Wasm function ${fn.name} expected $expected on the value stack, got $actual';
	}

	static function popAny(stack:Array<WasmValueType>, fn:WasmFunction):WasmValueType {
		if (stack.length == 0)
			throw 'Wasm function ${fn.name} underflowed the value stack';
		return stack.pop();
	}

	static function reset(stack:Array<WasmValueType>, height:Int, result:Null<WasmValueType>, reachable:Bool, fn:WasmFunction):Void {
		if (reachable && stack.length < height)
			throw 'Wasm function ${fn.name} ended a control frame with too few values';
		while (stack.length > height)
			stack.pop();
		if (reachable && result != null)
			stack.push(result);
	}

	static function validateBranch(controls:Array<WasmControl>, depth:Int, fn:WasmFunction):Void {
		if (depth < 0 || depth >= controls.length)
			throw 'Wasm function ${fn.name} branches to invalid stack depth $depth';
	}

	static function validateDepth(fn:WasmFunction, depth:Int, labelCount:Int):Void
		if (depth < 0 || depth >= labelCount)
			throw 'Wasm function ${fn.name} has an invalid branch-table depth $depth';
}
