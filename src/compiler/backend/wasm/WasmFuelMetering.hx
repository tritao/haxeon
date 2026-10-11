package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

private enum FuelControl {
	FuelBlock;
	FuelLoop;
	FuelIf;
	FuelTry;
}

/** Adds one host-backed charge at every defined function entry and Wasm loop back-edge. */
class WasmFuelMetering {
	public static function instrument(module:WasmModule, fuelFunction:Int):Void {
		for (offset in 0...module.functions.length) {
			var functionIndex = module.imports.length + offset,
				fn = module.functions[offset];
			if (functionIndex == fuelFunction || fn.encodedBody != null)
				continue;
			var locals = fn.locals.copy(),
				body = rewrite(fn.body, locals, fn.type.parameters.length, fuelFunction);
			body.unshift(Call(fuelFunction));
			module.setFunction(functionIndex, new WasmFunction(fn.name, fn.type, locals, body));
		}
	}

	static function rewrite(instructions:Array<WasmInstruction>, locals:Array<WasmLocal>, parameterCount:Int, fuelFunction:Int):Array<WasmInstruction> {
		var result:Array<WasmInstruction> = [],
			controls:Array<FuelControl> = [],
			branchTableLocal = -1;
		for (instruction in instructions) {
			switch instruction {
				case Br(depth):
					if (targetsLoop(controls, depth))
						result.push(Call(fuelFunction));
					result.push(instruction);
				case BrIf(depth) if (targetsLoop(controls, depth)):
					// `if` consumes the original condition. Charge only on the taken edge.
					result.push(If(null));
					result.push(Call(fuelFunction));
					result.push(Br(depth + 1));
					result.push(End);
				case BrTable(targets, defaultDepth) if (targetsTableLoop(controls, targets, defaultDepth)):
					if (branchTableLocal < 0) {
						branchTableLocal = parameterCount + locals.length;
						locals.push({type: I32});
					}
					// Expand only tables that contain a loop edge. This keeps the fuel call conditional
					// on the selected target while preserving the branch values below the selector.
					result.push(LocalSet(branchTableLocal));
					for (index in 0...targets.length) {
						result.push(LocalGet(branchTableLocal));
						result.push(I32Const(index));
						result.push(I32Eq);
						result.push(If(null));
						if (targetsLoop(controls, targets[index]))
							result.push(Call(fuelFunction));
						result.push(Br(targets[index] + 1));
						result.push(End);
					}
					if (targetsLoop(controls, defaultDepth))
						result.push(Call(fuelFunction));
					result.push(Br(defaultDepth));
				case Try(_) | TryTable(_, _) | Catch(_) | Throw(_):
					throw 'Runtime-neutral Wasm lowering left an exception instruction: ${Std.string(instruction)}';
				case Block(_):
					result.push(instruction);
					controls.push(FuelBlock);
				case Loop(_):
					result.push(instruction);
					controls.push(FuelLoop);
				case If(_):
					result.push(instruction);
					controls.push(FuelIf);
				case End:
					result.push(instruction);
					if (controls.length == 0)
						throw "Runtime-neutral fuel metering found an unmatched Wasm end";
					controls.pop();
				case instruction:
					result.push(instruction);
			}
		}
		if (controls.length != 0)
			throw "Runtime-neutral fuel metering found unterminated Wasm control flow";
		return result;
	}

	static function targetsLoop(controls:Array<FuelControl>, depth:Int):Bool {
		var index = controls.length - 1 - depth;
		if (index < 0)
			return false; // A branch to the implicit function label exits; it is not a loop back-edge.
		return controls[index] == FuelLoop;
	}

	static function targetsTableLoop(controls:Array<FuelControl>, targets:Array<Int>, defaultDepth:Int):Bool {
		for (depth in targets)
			if (targetsLoop(controls, depth))
				return true;
		return targetsLoop(controls, defaultDepth);
	}
}
