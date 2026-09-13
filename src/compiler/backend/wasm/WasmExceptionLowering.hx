package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmCatchClause;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** Rewrites the old structured catch form to the standardized try_table encoding. */
class WasmExceptionLowering {
	public static function lower(module:WasmModule):Void {
		var tagType = module.exceptionTagType;
		if (tagType == null)
			return;
		var tagParameters = module.functionTypeAt(tagType).parameters;
		if (tagParameters.length != 1)
			throw "Wasm try_table lowering currently requires one exception payload value";
		var payloadType = tagParameters[0];
		for (index in 0...module.functions.length) {
			var functionIndex = module.imports.length + index,
				fn = module.functions[index];
			module.setFunction(functionIndex, new WasmFunction(fn.name, fn.type, fn.locals, lowerSequence(fn.body, payloadType)));
		}
	}

	static function lowerSequence(instructions:Array<WasmInstruction>, payloadType:WasmValueType):Array<WasmInstruction> {
		var result:Array<WasmInstruction> = [], index = 0;
		while (index < instructions.length) {
			switch instructions[index] {
				case Try(tryResult):
					var catchIndex = -1, endIndex = -1, nestedControls = 0;
					for (candidate in index + 1...instructions.length) {
						switch instructions[candidate] {
							case Block(_) | Loop(_) | If(_) | Try(_) | TryTable(_, _):
								nestedControls++;
							case Catch(_) if (nestedControls == 0):
								if (catchIndex >= 0)
									throw "Wasm exception lowering does not support multiple catch clauses in one try";
								catchIndex = candidate;
							case End:
								if (nestedControls == 0) {
									endIndex = candidate;
									break;
								}
								nestedControls--;
							default:
						}
						if (endIndex >= 0)
							break;
					}
					if (catchIndex < 0 || endIndex < 0)
						throw "Wasm exception lowering found a try without a matching catch and end";
					var tag = switch instructions[catchIndex] {
						case Catch(value): value;
						default: throw "Wasm exception lowering lost a catch tag";
					}, protectedBody = lowerSequence(instructions.slice(index + 1, catchIndex),
						payloadType), catchBody = lowerSequence(instructions.slice(catchIndex + 1, endIndex), payloadType);
					shiftExternalBranches(protectedBody, 2);
					result.push(Block(null));
					result.push(Block(payloadType));
					result.push(TryTable(payloadType, [Tag(tag, 0)]));
					for (instruction in protectedBody)
						result.push(instruction);
					if (tryResult != null)
						result.push(Drop);
					result.push(Br(2));
					result.push(End);
					result.push(End);
					for (instruction in catchBody)
						result.push(instruction);
					result.push(End);
					index = endIndex + 1;
				case Catch(_):
					throw "Wasm exception lowering found a catch without a matching try";
				case TryTable(resultType, catches):
					result.push(TryTable(resultType, catches.copy()));
					index++;
				case instruction:
					result.push(instruction);
					index++;
			}
		}
		return result;
	}

	static function shiftExternalBranches(instructions:Array<WasmInstruction>, amount:Int):Void {
		// The new handler and continuation blocks add two labels around the old try body.
		var nestedControls = 0;
		for (index in 0...instructions.length) {
			var threshold = nestedControls;
			instructions[index] = switch instructions[index] {
				case Br(depth) if (depth >= threshold): Br(depth + amount);
				case BrIf(depth) if (depth >= threshold): BrIf(depth + amount);
				case BrTable(targets, defaultDepth):
					BrTable([for (depth in targets) depth >= threshold ? depth + amount : depth],
						defaultDepth >= threshold ? defaultDepth + amount : defaultDepth);
				case instruction: instruction;
			};
			switch instructions[index] {
				case Block(_) | Loop(_) | If(_) | Try(_) | TryTable(_, _):
					nestedControls++;
				case End:
					nestedControls--;
				default:
			}
		}
	}
}
